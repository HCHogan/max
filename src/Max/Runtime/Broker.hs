{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Socket-activated authority for Max-owned systemd instances. Requests never
-- select a host executable, path, uid, unit property, network or Nix expression.
module Max.Runtime.Broker (runRuntimeBroker) where

import Control.Concurrent (forkFinally, threadDelay)
import Control.Concurrent.Async (concurrently, race)
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Exception hiding (handle)
import Control.Monad (forM, forM_, forever, unless, void, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.IO qualified as TIO
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import GHC.Generics (Generic)
import GHC.IO.Handle (hDuplicate)
import Max.Runtime.Protocol
import Max.Util (trySyncIO)
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketIO
import System.Directory
import System.Environment (lookupEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath (dropExtension, takeExtension, (<.>), (</>))
import System.IO
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files qualified as Posix
import System.Posix.IO qualified as Posix
import System.Posix.Process (getProcessID)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Types (Fd (..), UserID)
import System.Posix.User (getEffectiveUserID, getUserEntryForName, userID)
import System.Process
import System.Timeout (timeout)

data Configuration = Configuration
  { user :: String,
    stateDirectory :: FilePath,
    gcRootsDirectory :: FilePath,
    legacyVolumeDirectory :: Maybe FilePath,
    nixpkgs :: FilePath,
    system :: Text,
    bridge :: String,
    subnet :: String,
    gateway :: String,
    dns :: [Text],
    generations :: Map.Map Text FilePath,
    commands :: Map.Map Text FilePath
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON)

data Metadata = Metadata
  {name :: Text, generation :: FilePath, policyVersion :: Text, address :: Maybe String, invocation :: Maybe Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data Broker = Broker
  { configuration :: Configuration,
    uid :: UserID,
    locks :: MVar (Map.Map Text (Int, MVar ())),
    addresses :: MVar ()
  }

data RuntimeFailure = RuntimeFailure Int Text deriving stock (Show)

instance Exception RuntimeFailure

failure :: Int -> Text -> IO a
failure code message = throwIO (RuntimeFailure code message)

require :: Bool -> Text -> IO ()
require condition = unless condition . failure 64

checkedName :: Maybe RuntimeKind -> Text -> IO InstanceName
checkedName expected value = do
  name <- either (failure 64) pure (parseInstanceName value)
  require (maybe True (== name.instanceKind) expected) "wrong runtime instance kind"
  pure name

-- Bounded, reference-counted locks: unrelated conversations may start together;
-- only address reservation briefly takes the broker-wide allocation lock.
withInstance :: Broker -> InstanceName -> IO a -> IO a
withInstance broker name action = mask $ \restore -> do
  lock <- modifyMVar broker.locks $ \locks -> do
    (count, lock) <- maybe ((0,) <$> newMVar ()) pure (Map.lookup name.fullName locks)
    pure (Map.insert name.fullName (count + 1, lock) locks, lock)
  let release =
        modifyMVar_ broker.locks $
          pure
            . Map.update
              (\(count, value) -> if count == 1 then Nothing else Just (count - 1, value))
              name.fullName
  restore (withMVar lock (const action)) `finally` release

tool :: Broker -> Text -> FilePath
tool broker name = fromMaybe (error "validated broker command missing") (Map.lookup name broker.configuration.commands)

instanceGeneration :: Broker -> InstanceName -> IO FilePath
instanceGeneration broker name = maybe (failure 125 "runtime backend is disabled") pure (Map.lookup kind broker.configuration.generations)
  where
    kind = case name.instanceKind of
      SandboxRuntime -> "sandbox"
      BrowserRuntime -> "browser"

decodeOutput :: BS.ByteString -> Text
decodeOutput = TE.decodeUtf8With lenientDecode

exitNumber :: ExitCode -> Int
exitNumber ExitSuccess = 0
exitNumber (ExitFailure value) = if value < 0 then 128 - value else value

ignoreMissing :: IO () -> IO ()
ignoreMissing action = action `catch` \err -> unless (isDoesNotExistError err) (throwIO err)

ignoreIO :: IO a -> IO ()
ignoreIO action = void action `catch` \(_ :: IOException) -> pure ()

-- All helper output is bounded, including package-search JSON. A failed or
-- timed-out helper is unavailability, never evidence that durable data vanished.
control :: Broker -> Text -> [String] -> Int -> Int -> IO (Int, Text, Text)
control broker command arguments seconds limit = do
  result <- timeout (seconds * 1000000)
    $ withCreateProcess
      (proc (tool broker command) arguments)
        { std_in = NoStream,
          std_out = CreatePipe,
          std_err = CreatePipe,
          create_group = True
        }
    $ \_ output errors process -> do
      let readBounded handle = go 0 []
            where
              go count chunks = do
                chunk <- BS.hGetSome handle 32768
                let total = count + BS.length chunk
                when (total > limit) (failure 125 "runtime helper output exceeded its limit")
                if BS.null chunk
                  then pure (decodeOutput (BS.concat (reverse chunks)))
                  else go total (chunk : chunks)
      let run = do
            (out, err) <-
              concurrently
                (readBounded (fromMaybe (error "stdout pipe") output))
                (readBounded (fromMaybe (error "stderr pipe") errors))
            code <- waitForProcess process
            pure (exitNumber code, out, err)
      run `onException` killProcessTree process
  maybe (failure 125 "runtime helper timed out") pure result

controlOK :: Broker -> Text -> [String] -> Int -> IO Text
controlOK broker command arguments seconds = do
  (code, output, errors) <- control broker command arguments seconds 1048576
  unless (code == 0) (failure 125 ("runtime helper failed: " <> T.takeEnd 2000 errors))
  pure output

killProcessTree :: ProcessHandle -> IO ()
killProcessTree process = do
  status <- getProcessExitCode process
  unless (isJust status) $ do
    pid <- getPid process
    forM_ pid (ignoreIO . signalProcessGroup sigTERM)
    stopped <- timeout 5000000 (waitForProcess process)
    unless (isJust stopped) $ do
      forM_ pid (ignoreIO . signalProcessGroup sigKILL)
      void (waitForProcess process)

metadataPath :: Broker -> InstanceName -> FilePath
metadataPath broker name = broker.configuration.stateDirectory </> "instances" </> T.unpack name.fullName <.> "json"

readMetadata :: Broker -> InstanceName -> IO (Maybe Metadata)
readMetadata broker name =
  ( do
      bytes <- BS.readFile (metadataPath broker name)
      record <- either (const (failure 125 "invalid runtime metadata")) pure (eitherDecodeStrict' bytes)
      unless (record.name == name.fullName) (failure 125 "runtime metadata identity mismatch")
      pure (Just record)
  )
    `catch` \err -> if isDoesNotExistError err then pure Nothing else throwIO err

metadata :: Broker -> InstanceName -> IO Metadata
metadata broker name = readMetadata broker name >>= maybe (failure 3 "no such instance") pure

saveMetadata :: Broker -> InstanceName -> Metadata -> IO ()
saveMetadata broker name record = do
  let path = metadataPath broker name
  LBS.writeFile (path <.> "tmp") (encode record)
  Posix.setFileMode (path <.> "tmp") 0o600
  renameFile (path <.> "tmp") path

unitState :: Broker -> InstanceName -> IO (Map.Map Text Text)
unitState broker name = do
  output <- controlOK broker "systemctl" ["show", instanceUnit name, "--property=LoadState,ActiveState,InvocationID"] 45
  let fields = Map.fromList [(key, T.drop 1 value) | line <- T.lines output, let (key, value) = T.breakOn "=" line, not (T.null value)]
  unless (Map.member "ActiveState" fields) (failure 125 "systemd returned no instance state")
  pure fields

field :: Text -> Map.Map Text Text -> Text
field = Map.findWithDefault ""

volumePath :: Broker -> InstanceName -> FilePath
volumePath broker name = broker.configuration.stateDirectory </> "volumes" </> T.unpack name.fullName <> "-data"

rootPath :: Broker -> InstanceName -> FilePath
rootPath broker name = broker.configuration.stateDirectory </> "roots" </> T.unpack name.fullName

legacyCheck :: Broker -> InstanceName -> IO ()
legacyCheck broker name = forM_ broker.configuration.legacyVolumeDirectory $ \directory -> do
  exists <- doesPathExist (directory </> T.unpack name.fullName <> "-data")
  when exists (failure 125 "legacy Docker work volume exists; migrate it before starting Max")

digest :: Text -> String
digest = T.unpack . TE.decodeUtf8 . Base16.encode . SHA256.hash . TE.encodeUtf8

networkNames :: InstanceName -> (String, String, String)
networkNames name = (T.unpack name.fullName, "max-sb-" <> suffix, "mp" <> suffix)
  where
    suffix = take 8 (digest name.fullName)

reserveAddress :: Broker -> InstanceName -> IO Metadata
reserveAddress broker name = withMVar broker.addresses $ \_ -> do
  names <- instanceNames broker
  records <- mapM (readMetadata broker) names
  let used = [value | Just record <- records, Just value <- [record.address]]
      candidates = ["10.231." <> show (index `div` 256) <> "." <> show (index `mod` 256) | index <- [2 .. 65534 :: Int]]
  address <- case filter (`notElem` used) candidates of
    value : _ -> pure value
    [] -> failure 125 "sandbox address pool exhausted"
  generation <- instanceGeneration broker name
  let record = Metadata name.fullName generation sandboxPolicyVersion (Just address) Nothing
  saveMetadata broker name record
  pure record

prepareNetwork :: Broker -> InstanceName -> String -> IO ()
prepareNetwork broker name address = do
  let (namespace, interface, peer) = networkNames name
      ip arguments = void (controlOK broker "ip" arguments 45)
      optional arguments = void (control broker "ip" arguments 45 1048576)
  optional ["netns", "del", namespace]
  optional ["link", "del", interface]
  ip ["netns", "add", namespace]
  ip ["link", "add", interface, "type", "veth", "peer", "name", peer]
  ip ["link", "set", peer, "netns", namespace]
  ip ["link", "set", interface, "master", broker.configuration.bridge]
  void (controlOK broker "bridge" ["link", "set", "dev", interface, "isolated", "on"] 45)
  ip ["link", "set", interface, "up"]
  ip ["-n", namespace, "link", "set", peer, "name", "eth0"]
  ip ["-n", namespace, "link", "set", "lo", "up"]
  ip ["-n", namespace, "addr", "add", address <> "/16", "dev", "eth0"]
  ip ["-n", namespace, "link", "set", "eth0", "up"]
  ip ["-n", namespace, "route", "add", "default", "via", broker.configuration.gateway]

stopInstance :: Broker -> InstanceName -> IO ()
stopInstance broker name = do
  before <- unitState broker name
  unless (field "LoadState" before == "not-found") $
    void (controlOK broker "systemctl" ["stop", instanceUnit name] 90)
  state <- unitState broker name
  unless (field "ActiveState" state `elem` ["inactive", "failed"]) (failure 125 "instance has not stopped")
  void (control broker "systemctl" ["reset-failed", instanceUnit name] 45 1048576)
  when (name.instanceKind == SandboxRuntime) $ do
    let (namespace, interface, _) = networkNames name
    void (control broker "ip" ["netns", "del", namespace] 45 1048576)
    void (control broker "ip" ["link", "del", interface] 45 1048576)
  -- /work is outside the expendable root. Never remove its data on stop.
  ignoreMissing (removePathForcibly (rootPath broker name))
  ignoreMissing (removeFile (metadataPath broker name))

startInstance :: Broker -> InstanceName -> IO ()
startInstance broker name = withInstance broker name $ do
  generation <- instanceGeneration broker name
  current <- readMetadata broker name
  state <- unitState broker name
  let reusable record = record.generation == generation && record.policyVersion == sandboxPolicyVersion && record.invocation == Just (field "InvocationID" state)
  unless (field "ActiveState" state == "active" && maybe False reusable current) $ do
    stopInstance broker name
    record <- case name.instanceKind of
      BrowserRuntime -> do
        let record = Metadata name.fullName generation sandboxPolicyVersion Nothing Nothing
        saveMetadata broker name record
        pure record
      SandboxRuntime -> do
        let volume = volumePath broker name
            work = volume </> "work"
            root = rootPath broker name
        exists <- doesDirectoryExist volume
        unless exists (legacyCheck broker name)
        createDirectoryIfMissing True work
        Posix.setFileMode work 0o700
        Posix.setOwnerAndGroup work 1000 1000
        forM_ ["", "etc", "usr", "usr/bin", "var", "run", "work", "nix", "nix/store"] $ \directory -> do
          createDirectoryIfMissing True (root </> directory)
          Posix.setFileMode (root </> directory) 0o755
        forM_ ["etc/os-release", "etc/machine-id"] $ \file -> do
          BS.writeFile (root </> file) ""
          Posix.setFileMode (root </> file) 0o644
        TIO.writeFile (root </> "etc/resolv.conf") (T.unlines (map ("nameserver " <>) broker.configuration.dns))
        Posix.setFileMode (root </> "etc/resolv.conf") 0o644
        record <- reserveAddress broker name
        forM_ record.address (prepareNetwork broker name)
        pure record
    void (controlOK broker "systemctl" ["start", instanceUnit name] 120)
    started <- unitState broker name
    unless (field "ActiveState" started == "active") (failure 125 "instance did not become active")
    saveMetadata broker name record {invocation = Just (field "InvocationID" started)}

instanceNames :: Broker -> IO [InstanceName]
instanceNames broker = do
  files <- sort <$> listDirectory (broker.configuration.stateDirectory </> "instances")
  forM [file | file <- files, takeExtension file == ".json"] $ checkedName Nothing . T.pack . dropExtension

-- The Unix socket is also the cancellation lease. Closing it stops the guest
-- transient unit, rather than merely terminating the systemd-run client.
execute :: Broker -> Socket.Socket -> (Handle, Handle, Handle) -> [String] -> Int -> Maybe (String, String) -> IO Int
execute broker socket streams command seconds guest = withCopies streams $ \(input, output, errors) -> case command of
  [] -> failure 125 "empty broker command"
  executable : arguments -> withCreateProcess
    (proc executable arguments)
      { std_in = UseHandle input,
        std_out = UseHandle output,
        std_err = UseHandle errors,
        create_group = True
      }
    $ \_ _ _ process -> do
      let cancel = do
            forM_ guest $ \(machine, unit) ->
              void (trySyncIO (control broker "systemctl" ["--machine=" <> machine, "stop", unit] 15 1048576))
            killProcessTree process
          run = do
            completed <- timeout (seconds * 1000000) (race (waitForProcess process) (SocketIO.recv socket 1))
            case completed of
              Just (Left code) -> pure (exitNumber code)
              Just (Right bytes) | not (BS.null bytes) -> failure 64 "unexpected data after runtime request"
              _ -> cancel >> pure 124
      run `onException` cancel
  where
    -- createProcess consumes UseHandle streams. Keep the admission-owned
    -- originals open until the handler has flushed and sent its response.
    withCopies (input, output, errors) action =
      bracket (hDuplicate input) hClose $ \inputCopy ->
        bracket (hDuplicate output) hClose $ \outputCopy ->
          bracket (hDuplicate errors) hClose $ \errorsCopy ->
            action (inputCopy, outputCopy, errorsCopy)

guestExec :: Broker -> InstanceName -> [Text] -> Socket.Socket -> (Handle, Handle, Handle) -> IO Int
guestExec broker name arguments socket handles = do
  require (not (null arguments) && length arguments <= 256 && not (any (T.any (== '\0')) arguments)) "invalid sandbox command"
  void (metadata broker name)
  identifier <- UUID.toString <$> UUID.nextRandom
  let unit = "max-exec-" <> identifier <> ".service"
      machine = instanceMachine name
      command =
        [ tool broker "systemd-run",
          "--machine=" <> machine,
          "--unit=" <> unit,
          "--uid=sandbox",
          "--gid=sandbox",
          "--working-directory=/work",
          "--pipe",
          "--wait",
          "--collect",
          "--quiet",
          "--service-type=exec",
          "--property=RuntimeMaxSec=3600",
          "--property=TimeoutStopSec=5",
          "--property=NoNewPrivileges=yes",
          "--property=CapabilityBoundingSet=",
          "--property=ProtectSystem=strict",
          "--property=ReadWritePaths=/work /tmp /home/sandbox",
          "--property=PrivateDevices=yes",
          "--property=RestrictSUIDSGID=yes",
          "--property=RestrictNamespaces=yes",
          "--property=ProtectControlGroups=yes",
          "--setenv=HOME=/home/sandbox",
          "--setenv=PATH=/run/current-system/sw/bin:/bin",
          "--",
          "/run/current-system/sw/bin/env",
          "--"
        ]
          <> map T.unpack arguments
  execute broker socket handles command 3660 (Just (machine, unit))

browserPort :: Broker -> InstanceName -> IO Int
browserPort broker name = do
  void (metadata broker name)
  result <- timeout 90000000 wait
  maybe (failure 125 "browser endpoint did not become ready") pure result
  where
    path = "/run/max-browser-" <> T.unpack name.instanceSuffix </> "endpoint.json"
    wait = do
      value <- (Just <$> readEndpoint) `catch` \err -> if isDoesNotExistError err then pure Nothing else throwIO err
      case value of
        Just port -> pure port
        Nothing -> do
          state <- unitState broker name
          unless (field "ActiveState" state `elem` ["active", "activating"]) (failure 125 "browser exited before publishing its endpoint")
          threadDelay 100000
          wait
    -- The browser controls this file: atomically refuse symlinks and special
    -- files so a compromised browser cannot make root read another host file.
    readEndpoint = bracket
      (Posix.openFd path Posix.ReadOnly Posix.defaultFileFlags {Posix.nofollow = True, Posix.nonBlock = True, Posix.cloexec = True})
      Posix.closeFd
      $ \descriptor -> do
        status <- Posix.getFdStatus descriptor
        unless (Posix.isRegularFile status && Posix.fileSize status <= 1024) (failure 125 "invalid browser endpoint file")
        bracket (Posix.dup descriptor >>= Posix.fdToHandle) hClose $ \handle -> do
          bytes <- BS.hGet handle 1025
          value <- either (const (failure 125 "invalid browser endpoint JSON")) pure (eitherDecodeStrict' bytes :: Either String (Map.Map Text Int))
          case Map.lookup "port" value of
            Just port | port >= 1024 && port <= 65535 -> pure port
            _ -> failure 125 "invalid browser endpoint port"

handleRequest :: Broker -> Socket.Socket -> (Handle, Handle, Handle) -> RuntimeRequest -> IO Int
handleRequest broker socket handles@(_, output, _) request = do
  let put = TIO.hPutStrLn output
      sandbox = checkedName (Just SandboxRuntime)
      browser = checkedName (Just BrowserRuntime)
  case request of
    StartSandbox value profile volume network -> do
      name <- sandbox value
      require (profile == "nixos-sandbox-v1" && network == "max-sandbox" && volume == value <> "-data") "unsupported sandbox policy or volume"
      startInstance broker name
      put value
      pure 0
    StartBrowser value -> browser value >>= startInstance broker >> put value >> pure 0
    StopInstance value -> do
      name <- checkedName Nothing value
      withInstance broker name (stopInstance broker name)
      pure 0
    ListInstances kind -> do
      names <- instanceNames broker
      forM_ [name.fullName | name <- names, name.instanceKind == kind] put
      pure 0
    ListVolumes -> do
      volumes <- sort <$> listDirectory (broker.configuration.stateDirectory </> "volumes")
      -- Offline migration deliberately retains incomplete staging copies.
      -- They are not published work volumes and must not break discovery.
      forM_ (filter (not . T.isPrefixOf ".migration-" . T.pack) volumes) $ \volume ->
        either (failure 125) (const (put (T.pack volume))) (parseVolumeName (T.pack volume))
      pure 0
    InspectVolume value -> withVolume value $ \_ _ -> put "present" >> pure 0
    RemoveVolume value -> withVolume value $ \name path -> do
      state <- unitState broker name
      unless (field "ActiveState" state `elem` ["inactive", "failed"]) (failure 125 "cannot remove an active work volume")
      removePathForcibly path
      ignoreMissing (removePathForcibly (broker.configuration.gcRootsDirectory </> T.unpack name.fullName))
      pure 0
    InspectInstance value -> do
      name <- checkedName Nothing value
      void (metadata broker name)
      state <- unitState broker name
      put (if field "ActiveState" state == "active" then "running" else "stopped")
      pure 0
    InspectPolicy value -> do
      name <- sandbox value
      generation <- instanceGeneration broker name
      record <- metadata broker name
      state <- unitState broker name
      let current = record.generation == generation && record.policyVersion == sandboxPolicyVersion && record.invocation == Just (field "InvocationID" state)
      put ((if current then sandboxPolicyVersion else "old") <> " max-sandbox 1")
      pure 0
    BrowserEndpoint value -> browser value >>= browserPort broker >>= put . T.pack . show >> pure 0
    RunCommand value arguments -> sandbox value >>= \name -> guestExec broker name arguments socket handles
    PreparePackages value seconds attributes -> do
      name <- sandbox value
      require (seconds >= 1 && seconds <= 3600) "invalid package build deadline"
      expression <- either (failure 64) pure (packageExpression broker.configuration.nixpkgs broker.configuration.system attributes)
      withInstance broker name $ do
        void (metadata broker name)
        let roots = broker.configuration.gcRootsDirectory </> T.unpack name.fullName
        createDirectoryIfMissing True roots
        execute
          broker
          socket
          handles
          [ tool broker "nix",
            "build",
            "--extra-experimental-features",
            "nix-command flakes",
            "--impure",
            "--out-link",
            roots </> digest expression,
            "--print-out-paths",
            "--expr",
            T.unpack expression
          ]
          (seconds + 5)
          Nothing
    SearchPackages value query -> do
      name <- sandbox value
      require (T.length query <= 512 && not (T.any (== '\0') query)) "invalid package search"
      void (metadata broker name)
      (code, bytes, errors) <-
        control
          broker
          "nix"
          [ "search",
            "--extra-experimental-features",
            "nix-command flakes",
            "--json",
            "path:" <> broker.configuration.nixpkgs,
            "--",
            T.unpack query
          ]
          120
          33554432
      unless (code == 0) (failure 125 (T.takeEnd 2000 errors))
      records <-
        either
          (const (failure 125 "invalid package search response"))
          pure
          (eitherDecodeStrict' (TE.encodeUtf8 bytes) :: Either String (Map.Map Text (Map.Map Text Text)))
      forM_ (take 30 (Map.toAscList records)) $ \(key, entry) ->
        put (T.intercalate "." (drop 2 (T.splitOn "." key)) <> " " <> field "version" entry <> " " <> field "description" entry)
      pure 0
  where
    withVolume value action = do
      name <- either (failure 64) pure (parseVolumeName value)
      withInstance broker name $ do
        let path = volumePath broker name
        exists <- doesDirectoryExist path
        unless exists (legacyCheck broker name >> failure 3 "no such volume")
        action name path

serveConnection :: Broker -> Socket.Socket -> IO ()
serveConnection broker socket = do
  result <- trySyncIO $ do
    (_, uid, _) <- Socket.getPeerCredential socket
    unless (uid == Just 0 || uid == Just (fromIntegral broker.uid)) (failure 77 "runtime peer is not authorized")
    -- Timeout only admission, not a running command. All descriptor brackets
    -- remain live until the operation and its streaming writes have completed.
    withRuntimeStreams socket $ \handles@(_, output, errors) -> do
      framed <- timeout 10000000 (receiveFrame 262144 socket)
      (version, request) <- maybe (failure 64 "runtime request timed out") pure framed
      require (version == runtimeProtocolVersion) "runtime protocol version mismatch"
      code <- handleRequest broker socket handles request
      hFlush output
      hFlush errors
      pure code
  let response = case result of
        Right code -> RuntimeResponse runtimeProtocolVersion code Nothing
        Left err -> case fromException err of
          Just (RuntimeFailure code message) -> RuntimeResponse runtimeProtocolVersion code (Just (T.take 4000 message))
          Nothing -> RuntimeResponse runtimeProtocolVersion 125 (Just (T.take 4000 (T.pack (displayException err))))
  ignoreIO (sendFrame socket response)

runRuntimeBroker :: FilePath -> IO ()
runRuntimeBroker path = do
  uid <- getEffectiveUserID
  unless (uid == 0) (failure 77 "runtime broker must run as root")
  configuration <- BS.readFile path >>= either (failure 125 . T.pack) pure . eitherDecodeStrict'
  require (configuration.subnet == "10.231.0.0/16" && configuration.gateway == "10.231.0.1") "unsupported sandbox address pool"
  forM_ ["systemctl", "systemd-run", "ip", "bridge", "nix"] $ \command ->
    require (maybe False (T.isPrefixOf "/nix/store/" . T.pack) (Map.lookup command configuration.commands)) "broker executables must be store paths"
  peer <- userID <$> getUserEntryForName configuration.user
  locks <- newMVar Map.empty
  addresses <- newMVar ()
  let broker = Broker configuration peer locks addresses
  forM_ ["instances", "roots", "volumes"] $ \directory -> do
    let target = configuration.stateDirectory </> directory
    createDirectoryIfMissing True target
    Posix.setFileMode target 0o700
  pid <- getProcessID
  listenPid <- lookupEnv "LISTEN_PID"
  listenFds <- lookupEnv "LISTEN_FDS"
  unless (listenPid == Just (show pid) && listenFds == Just "1") (failure 125 "runtime broker must be socket activated")
  unsetEnv "LISTEN_PID"
  unsetEnv "LISTEN_FDS"
  Posix.setFdOption (Fd 3) Posix.CloseOnExec True
  -- systemd hands over a blocking listener. network's accept expects a
  -- nonblocking descriptor; otherwise the next accept can stall the RTS
  -- before the just-forked request handler gets to run.
  Posix.setFdOption (Fd 3) Posix.NonBlockingRead True
  slots <- newQSem 16
  bracket (Socket.mkSocket 3) Socket.close $ \listener -> forever $
    -- Reserve before accept: kernel backlog bounds waiting connections.
    mask $ \restore -> do
      restore (waitQSem slots)
      (socket, _) <- restore (Socket.accept listener) `onException` signalQSem slots
      void (forkFinally (restore (serveConnection broker socket)) (const (Socket.close socket `finally` signalQSem slots)))
