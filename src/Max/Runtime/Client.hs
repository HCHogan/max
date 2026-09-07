-- | Unprivileged runtime client. Host files are opened here, never by the broker.
module Max.Runtime.Client (runRuntimeClient, requestRuntime) where

import Control.Concurrent.Async (concurrently, link, withAsync)
import Control.Exception (IOException, bracket, catch, finally, throwIO)
import Control.Monad (forM_, unless)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import GHC.IO.Handle (hDuplicate)
import Max.Runtime.Protocol
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketIO
import System.Environment (lookupEnv)
import System.IO
import System.IO.Error (isResourceVanishedError)
import System.Posix.IO (closeFd, createPipe, fdToHandle, handleToFd)

requestRuntime :: FilePath -> RuntimeRequest -> (Handle, Handle, Handle) -> IO RuntimeResponse
requestRuntime path request (input, output, errors) =
  bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \socket -> do
    Socket.connect socket (Socket.SockAddrUnix path)
    pipe $ \remoteInput inputWriter -> pipe $ \outputReader remoteOutput -> pipe $ \errorsReader remoteErrors -> do
      -- Pass only pipes. In particular, never let a caller make the root
      -- broker write to a Unix socket using root's per-message credentials.
      forM_ [remoteInput, remoteOutput, remoteErrors] $ \handle -> do
        bracket (hDuplicate handle >>= handleToFd) closeFd $ \descriptor -> Socket.sendFd socket (fromIntegral descriptor)
        acknowledgement <- SocketIO.recv socket 1
        unless (acknowledgement == BS.singleton 6) (throwIO (userError "runtime rejected stream descriptor"))
      forM_ [remoteInput, remoteOutput, remoteErrors] hClose
      sendFrame socket (runtimeProtocolVersion, request)
      let inputPump =
            (pump input inputWriter `catch` \err -> unless (isResourceVanishedError err) (throwIO err))
              `finally` hClose inputWriter
      withAsync inputPump $ \writer -> do
        link writer
        (response, _) <-
          concurrently
            (receiveFrame 8192 socket)
            (concurrently (pump outputReader output) (pump errorsReader errors))
        unless (response.protocol == runtimeProtocolVersion) (throwIO (userError "runtime protocol version mismatch"))
        pure response
  where
    pipe action =
      bracket
        (createPipe >>= \(reader, writer) -> (,) <$> fdToHandle reader <*> fdToHandle writer)
        (\(reader, writer) -> quietlyClose reader >> quietlyClose writer)
        (uncurry action)
    quietlyClose handle = hClose handle `catch` \(_ :: IOException) -> pure ()
    pump source destination = do
      chunk <- BS.hGetSome source 32768
      unless (BS.null chunk) (BS.hPut destination chunk >> hFlush destination >> pump source destination)

runRuntimeClient :: [String] -> IO Int
runRuntimeClient arguments = do
  path <- fromMaybe "/run/max-runtime/control.sock" <$> lookupEnv "MAX_RUNTIME_SOCKET"
  withStream stdin ReadMode $ \input -> withStream stdout WriteMode $ \output -> withStream stderr WriteMode $ \errors -> do
    let request value handles = do
          response <- requestRuntime path value handles
          forM_ response.errorMessage (TIO.hPutStrLn errors)
          pure response.exitCode
    case arguments of
      ["copy-to", name, source, destination] -> withBinaryFile source ReadMode $ \file ->
        request (RunCommand (T.pack name) ["sh", "-c", "cat > " <> shellQuote (T.pack destination)]) (file, output, errors)
      ["copy-from", name, source, destination] -> withBinaryFile destination WriteMode $ \file ->
        request (RunCommand (T.pack name) ["cat", "--", T.pack source]) (input, file, errors)
      _ -> case parseRuntimeArgs (map T.pack arguments) of
        Left errorMessage -> TIO.hPutStrLn errors errorMessage >> pure 64
        Right value -> request value (input, output, errors)
  where
    withStream handle mode action = do
      duplicate <- (Just <$> hDuplicate handle) `catch` \(_ :: IOException) -> pure Nothing
      case duplicate of
        Just valid -> bracket (pure valid) hClose action
        Nothing -> withBinaryFile "/dev/null" mode action
