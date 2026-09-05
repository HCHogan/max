{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Synchronous local control protocol for systemd's @ExecReload=@.
--
-- The protocol intentionally carries no configuration values.  The running
-- process re-reads its configured source, applies the schema it understands,
-- and reports only field names plus a stable error category.
module Max.Reload
  ( ReloadRequest (..),
    ReloadResponse (..),
    ReloadError (..),
    reloadProtocolVersion,
    controlSocketPath,
    runReloadServer,
    requestReload,
  )
where

import Control.Exception (IOException, bracket, throwIO, try)
import Control.Monad (forever, unless, void, when)
import Data.Aeson
  ( FromJSON,
    ToJSON,
    eitherDecodeStrict',
    encode,
  )
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Word (Word64)
import Effectful
import Effectful.Exception (finally)
import GHC.Generics (Generic)
import Max.Util (trySyncIO)
import Network.Socket
  ( Family (AF_UNIX),
    SockAddr (SockAddrUnix),
    Socket,
    SocketType (Stream),
    accept,
    bind,
    close,
    connect,
    defaultProtocol,
    listen,
    socket,
    socketToHandle,
    withSocketsDo,
  )
import System.Directory (createDirectoryIfMissing, doesPathExist, getCurrentDirectory, removeFile)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import System.IO (BufferMode (LineBuffering), IOMode (ReadWriteMode), hClose, hSetBuffering)
import System.Posix.Files (fileOwner, getSymbolicLinkStatus, isSocket, setFileMode)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

reloadProtocolVersion :: Int
reloadProtocolVersion = 1

data ReloadRequest = ReloadRequest
  { rrProtocol :: !Int,
    rrCommand :: !Text
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ReloadError
  = ReloadProtocolMismatch
  | ReloadInvalidRequest
  | ReloadConfigInvalid
  | ReloadRestartRequired
  | ReloadPreparationFailed
  | ReloadTimedOut
  | ReloadInternalFailure
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ReloadResponse = ReloadResponse
  { rpOk :: !Bool,
    rpOldGeneration :: !Word64,
    rpNewGeneration :: !Word64,
    rpChangedFields :: ![Text],
    rpRestartFields :: ![Text],
    rpError :: !(Maybe ReloadError)
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A stable socket path.  systemd supplies @RUNTIME_DIRECTORY@; local runs
-- may override it explicitly and otherwise use a private uid-qualified path
-- below the working tree's @var/@ directory.
controlSocketPath :: IO FilePath
controlSocketPath = do
  explicit <- lookupEnv "MAX_CONTROL_SOCKET"
  runtimeDir <- lookupEnv "RUNTIME_DIRECTORY"
  case explicit of
    Just path | not (null path) -> pure path
    _ -> case runtimeDir of
      Just dir | not (null dir) -> pure (dir </> "control.sock")
      _ -> do
        cwd <- getCurrentDirectory
        uid <- getEffectiveUserID
        pure (cwd </> "var" </> ("control-" <> show uid <> ".sock"))

runReloadServer ::
  (IOE :> es) =>
  FilePath ->
  Eff es ReloadResponse ->
  Eff es ()
runReloadServer path perform = do
  liftIO (prepareSocketPath path)
  listener <- liftIO (openListener path)
  ( do
      withRunInIO $ \run -> forever $ do
        (conn, _) <- accept listener
        serveConnection conn (run perform)
    )
    `finally` liftIO (close listener >> removeSocketIfPresent path)

requestReload :: FilePath -> IO (Either Text ReloadResponse)
requestReload path = withSocketsDo $ do
  attempted <- try @IOException $ do
    timed <- timeout clientTimeoutMicros $ bracket open hClose $ \handle -> do
      LBS.hPutStr handle (encode (ReloadRequest reloadProtocolVersion "reload") <> "\n")
      line <- BS8.hGetLine handle
      pure $ case eitherDecodeStrict' line of
        Left _ -> Left "max reload returned an invalid response"
        Right response -> Right response
    pure (fromMaybe (Left "timed out waiting for Max to finish reloading") timed)
  pure $ case attempted of
    Left _ -> Left "could not connect to the Max reload control socket"
    Right response -> response
  where
    open = do
      sock <- socket AF_UNIX Stream defaultProtocol
      connect sock (SockAddrUnix path)
      handle <- socketToHandle sock ReadWriteMode
      hSetBuffering handle LineBuffering
      pure handle

serveConnection :: Socket -> IO ReloadResponse -> IO ()
serveConnection conn perform = bracket (socketToHandle conn ReadWriteMode) hClose $ \handle -> do
  hSetBuffering handle LineBuffering
  input <- timeout requestReadTimeoutMicros (try @IOException (BS8.hGetLine handle))
  response <- case input of
    Nothing -> pure invalidRequest
    Just (Left _) -> pure invalidRequest
    Just (Right line) -> case (eitherDecodeStrict' line :: Either String ReloadRequest) of
      Left _ -> pure invalidRequest
      Right request
        | request.rrProtocol /= reloadProtocolVersion -> pure protocolMismatch
        | request.rrCommand /= "reload" -> pure invalidRequest
        | otherwise -> do
            -- The application owns its pre-publication deadline.  A timeout
            -- around the whole callback could interrupt after the atomic
            -- publish and lie to the caller that the old generation survived.
            -- Once commit starts it is short and retirement is independently
            -- bounded; before commit the application may truthfully return
            -- 'ReloadTimedOut' while the old generation is still authoritative.
            outcome <- trySyncIO perform
            pure $ case outcome of
              Left _ -> internalFailure
              Right result -> result
  LBS.hPutStr handle (encode response <> "\n")
  where
    emptyResponse err = ReloadResponse False 0 0 [] [] (Just err)
    invalidRequest = emptyResponse ReloadInvalidRequest
    protocolMismatch = emptyResponse ReloadProtocolMismatch
    internalFailure = emptyResponse ReloadInternalFailure

requestReadTimeoutMicros, clientTimeoutMicros :: Int
requestReadTimeoutMicros = 5 * 1_000_000
clientTimeoutMicros = 25 * 1_000_000

openListener :: FilePath -> IO Socket
openListener path = withSocketsDo $ do
  listener <- socket AF_UNIX Stream defaultProtocol
  bind listener (SockAddrUnix path)
  setFileMode path 0o600
  listen listener 16
  pure listener

prepareSocketPath :: FilePath -> IO ()
prepareSocketPath path = do
  createDirectoryIfMissing True (takeDirectory path)
  exists <- doesPathExist path
  if not exists
    then pure ()
    else do
      status <- getSymbolicLinkStatus path
      unless (isSocket status) $
        throwIO (userError "reload control path exists and is not a socket")
      uid <- getEffectiveUserID
      unless (fileOwner status == uid) $
        throwIO (userError "reload control socket is not owned by the service user")
      removeFile path

removeSocketIfPresent :: FilePath -> IO ()
removeSocketIfPresent path = do
  exists <- doesPathExist path
  when exists $ void (try @IOException (removeFile path))
