{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | Shared, versioned protocol for the unprivileged client and root broker.
-- Instance identifiers are validated before deriving any host path or unit.
module Max.Runtime.Protocol
  ( RuntimeKind (..),
    RuntimeRequest (..),
    RuntimeResponse (..),
    InstanceName (..),
    parseInstanceName,
    parseVolumeName,
    instanceUnit,
    instanceMachine,
    parseRuntimeArgs,
    validAttributes,
    packageExpression,
    sendFrame,
    receiveFrame,
    withRuntimeStreams,
    runtimeProtocolVersion,
    sandboxPolicyVersion,
    shellQuote,
  )
where

import Control.Exception (bracket, mask_, onException, throwIO)
import Control.Monad (unless)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict', encode)
import Data.Bits (shiftL, shiftR, (.|.))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import GHC.Generics (Generic)
import Network.Socket (Socket)
import Network.Socket qualified as Network
import Network.Socket.ByteString qualified as Socket
import System.IO (Handle, hClose, hSetBinaryMode)
import System.Posix.Files (getFdStatus, isNamedPipe)
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)
import Text.Read (readMaybe)

data RuntimeKind = SandboxRuntime | BrowserRuntime
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

data RuntimeRequest
  = StartSandbox Text Text Text Text
  | StartBrowser Text
  | StopInstance Text
  | ListInstances RuntimeKind
  | ListVolumes
  | InspectVolume Text
  | RemoveVolume Text
  | InspectInstance Text
  | InspectPolicy Text
  | BrowserEndpoint Text
  | RunCommand Text [Text]
  | PreparePackages Text Int [Text]
  | SearchPackages Text Text
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

data RuntimeResponse = RuntimeResponse
  {protocol :: Int, exitCode :: Int, errorMessage :: Maybe Text}
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

runtimeProtocolVersion :: Int
runtimeProtocolVersion = 1

-- Bump when the broker's sandbox isolation contract changes. Persisted
-- instances must match both this version and the host module generation.
sandboxPolicyVersion :: Text
sandboxPolicyVersion = "6"

-- | Every stream is an anonymous pipe created by the client. Reject sockets,
-- devices and regular files before any privileged helper can inherit them.
withRuntimeStreams :: Socket -> ((Handle, Handle, Handle) -> IO a) -> IO a
withRuntimeStreams socket action = one $ \input -> one $ \output -> one $ \errors -> action (input, output, errors)
  where
    one = bracket acquire hClose
    acquire = mask_ $ do
      received <- timeout 10000000 (Network.recvFd socket)
      descriptor <- maybe (throwIO (userError "runtime descriptor timed out")) (pure . Fd) received
      let prepare = do
            status <- getFdStatus descriptor
            unless (isNamedPipe status) (throwIO (userError "runtime streams must be pipes"))
            Posix.setFdOption descriptor Posix.CloseOnExec True
            Posix.fdToHandle descriptor
      handle <- prepare `onException` Posix.closeFd descriptor
      -- SCM_RIGHTS rides a byte stream. Acknowledge each descriptor before
      -- the sender emits another descriptor or a JSON frame, so recvFd
      -- cannot coalesce and discard the following payload on macOS.
      (hSetBinaryMode handle True >> Socket.sendAll socket (BS.singleton 6)) `onException` hClose handle
      pure handle

data InstanceName = InstanceName
  {fullName :: Text, instanceKind :: RuntimeKind, instanceSuffix :: Text}
  deriving stock (Show, Eq)

parseInstanceName :: Text -> Either Text InstanceName
parseInstanceName name
  | T.length name > 60 = Left "invalid Max instance name"
  | Just suffix <- T.stripPrefix "max-br-" name,
    canonicalInteger suffix =
      Right (InstanceName name BrowserRuntime suffix)
  | Just suffix <- T.stripPrefix "max-sb-" name,
    let (groupPrefix, ordinal) = T.breakOnEnd "-s" suffix,
    not (T.null groupPrefix),
    canonicalInteger (T.dropEnd 2 groupPrefix),
    Just number <- readMaybe @Int64 (T.unpack ordinal),
    number > 0,
    T.pack (show number) == ordinal =
      Right (InstanceName name SandboxRuntime suffix)
  | otherwise = Left "invalid Max instance name"
  where
    canonicalInteger value = case readMaybe @Int64 (T.unpack value) of
      Just number -> T.pack (show number) == value
      Nothing -> False

parseVolumeName :: Text -> Either Text InstanceName
parseVolumeName volume = do
  name <- maybe (Left "invalid Max work volume") Right (T.stripSuffix "-data" volume)
  instanceName <- parseInstanceName name
  if instanceName.instanceKind == SandboxRuntime then Right instanceName else Left "invalid Max work volume"

instanceUnit :: InstanceName -> String
instanceUnit name = "max-" <> kindName name.instanceKind <> "@" <> T.unpack name.instanceSuffix <> ".service"

instanceMachine :: InstanceName -> String
instanceMachine name = "max-" <> kindName name.instanceKind <> "-" <> T.unpack name.instanceSuffix

kindName :: RuntimeKind -> String
kindName SandboxRuntime = "sandbox"
kindName BrowserRuntime = "browser"

parseRuntimeArgs :: [Text] -> Either Text RuntimeRequest
parseRuntimeArgs = \case
  ["create", name, profile, volume, network] -> Right (StartSandbox name profile volume network)
  ["browser-create", name] -> Right (StartBrowser name)
  ["remove", name] -> Right (StopInstance name)
  ["list", "max-sb-"] -> Right (ListInstances SandboxRuntime)
  ["list", "max-br-"] -> Right (ListInstances BrowserRuntime)
  ["volumes", "max-sb-"] -> Right ListVolumes
  ["volume-status", name] -> Right (InspectVolume name)
  ["volume-remove", name] -> Right (RemoveVolume name)
  ["status", name] -> Right (InspectInstance name)
  ["policy", name] -> Right (InspectPolicy name)
  ["browser-port", name] -> Right (BrowserEndpoint name)
  "exec" : args -> case dropExecFlags args of
    Right (name : command@(_ : _)) -> Right (RunCommand name command)
    _ -> Left "missing sandbox command or invalid working directory"
  "build" : name : seconds : attributes
    | Just duration <- readMaybe (T.unpack seconds) -> Right (PreparePackages name duration attributes)
  ["search", name, query] -> Right (SearchPackages name query)
  _ -> Left "unsupported runtime operation"
  where
    dropExecFlags ("-i" : rest) = dropExecFlags rest
    dropExecFlags ("--workdir" : "/work" : rest) = dropExecFlags rest
    dropExecFlags ("--workdir" : _) = Left ()
    dropExecFlags rest = Right rest

validAttributes :: [Text] -> Bool
validAttributes attributes = not (null attributes) && length attributes <= 32 && all valid attributes
  where
    valid value = T.length value <= 200 && all segment (T.splitOn "." value)
    segment value = case T.uncons value of
      Just (first, rest) -> start first && T.all continuation rest
      Nothing -> False
    start c = isAsciiLower c || isAsciiUpper c || c == '_'
    continuation c = start c || isDigit c || c == '-' || c == '\''

packageExpression :: FilePath -> Text -> [Text] -> Either Text Text
packageExpression source system attributes
  | not (validAttributes attributes) = Left "invalid package attributes"
  | otherwise =
      Right $
        "let pkgs = import "
          <> T.pack source
          <> " { system = "
          <> quote system
          <> "; }; in [ "
          <> T.unwords (ordinary <> python)
          <> " ]"
  where
    quote = TE.decodeUtf8 . LBS.toStrict . encode
    access root value = root <> "." <> T.intercalate "." (map quote (T.splitOn "." value))
    ordinary = [access "pkgs" value | value <- attributes, not ("python3Packages." `T.isPrefixOf` value)]
    pythonAttributes = [value | attribute <- attributes, Just value <- [T.stripPrefix "python3Packages." attribute]]
    python = ["(pkgs.python3.withPackages (ps: [ " <> T.unwords (map (access "ps") pythonAttributes) <> " ]))" | not (null pythonAttributes)]

shellQuote :: Text -> Text
shellQuote value = "'" <> T.replace "'" "'\\''" value <> "'"

sendFrame :: (ToJSON value) => Socket -> value -> IO ()
sendFrame socket value = do
  let payload = LBS.toStrict (encode value)
      size = BS.length payload
  if size > 262144
    then throwIO (userError "runtime frame exceeds 256 KiB")
    else do
      Socket.sendAll socket (BS.pack [fromIntegral (size `shiftR` bits) | bits <- [24, 16, 8, 0]])
      Socket.sendAll socket payload

receiveFrame :: (FromJSON value) => Int -> Socket -> IO value
receiveFrame limit socket = do
  header <- receiveExactly 4
  let size = BS.foldl' (\value byte -> (value `shiftL` 8) .|. fromIntegral byte) (0 :: Int) header
  if size <= 0 || size > limit
    then throwIO (userError "invalid runtime frame size")
    else do
      payload <- receiveExactly size
      either (throwIO . userError) pure (eitherDecodeStrict' payload)
  where
    receiveExactly count = go count []
    go 0 chunks = pure (BS.concat (reverse chunks))
    go remaining chunks = do
      chunk <- Socket.recv socket remaining
      if BS.null chunk
        then throwIO (userError "runtime connection closed before completion")
        else go (remaining - BS.length chunk) (chunk : chunks)
