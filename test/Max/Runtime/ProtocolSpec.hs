module Max.Runtime.ProtocolSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Control.Exception (bracket)
import Control.Monad (forM_, replicateM_)
import Data.Aeson (eitherDecode, encode)
import Data.ByteString qualified as BS
import Data.Either (isLeft)
import Data.Text qualified as T
import GHC.IO.Handle (hDuplicate)
import Max.Runtime.Client (requestRuntime)
import Max.Runtime.Protocol
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketIO
import System.FilePath ((</>))
import System.IO
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.IO (closeFd, createPipe, fdToHandle, handleToFd)
import Test.Hspec

spec :: Spec
spec = do
  describe "runtime authority" $ do
    it "maps persistent positive and negative conversation identifiers to fixed units" $ do
      fmap instanceUnit (parseInstanceName "max-sb--812024380-s15") `shouldBe` Right "max-sandbox@-812024380-s15.service"
      fmap instanceMachine (parseInstanceName "max-sb--812024380-s15") `shouldBe` Right "max-sandbox--812024380-s15"
      fmap instanceUnit (parseInstanceName "max-br-728502470") `shouldBe` Right "max-browser@728502470.service"
    it "refuses paths, unit escapes, extra arguments and noncanonical or overflowing identifiers"
      $ forM_
        [ "../../etc/passwd",
          "max-sb-1-s1/../x",
          "max-sb-1-s0",
          "max-sb-1-s01",
          "max-br-01",
          "max-br--0",
          "max-br-1.service",
          "max-br-1 --uid=root",
          "max-br-9223372036854775808",
          "max-sb-1-s1\\x2f"
        ]
      $ \name ->
        parseInstanceName name `shouldSatisfy` isLeft
    it "accepts only sandbox work volumes" $ do
      fmap fullName (parseVolumeName "max-sb-1-s2-data") `shouldBe` Right "max-sb-1-s2"
      parseVolumeName "max-br-1-data" `shouldSatisfy` isLeft
    it "does not allow caller-selected host directories or service properties" $ do
      parseRuntimeArgs ["exec", "--workdir", "/etc", "max-sb-1-s1", "cat", "passwd"] `shouldSatisfy` isLeft
      parseRuntimeArgs ["systemctl", "start", "sshd"] `shouldSatisfy` isLeft
      parseRuntimeArgs ["exec", "--workdir", "/work", "max-sb-1-s1", "sh", "-c", "echo ok"]
        `shouldBe` Right (RunCommand "max-sb-1-s1" ["sh", "-c", "echo ok"])
  describe "pinned package preparation" $ do
    it "quotes attribute segments and combines Python modules into one environment" $ do
      let expression = packageExpression "/nix/store/source" "x86_64-linux" ["qpdf", "python3Packages.openpyxl", "python3Packages.pandas"]
      expression `shouldBe` Right "let pkgs = import /nix/store/source { system = \"x86_64-linux\"; }; in [ pkgs.\"qpdf\" (pkgs.python3.withPackages (ps: [ ps.\"openpyxl\" ps.\"pandas\" ])) ]"
    it "refuses expressions, flake URLs, empty segments and unbounded lists" $ do
      forM_
        [ [],
          ["github:owner/repo"],
          ["foo..bar"],
          ["foo; builtins.readFile /etc/shadow"],
          ["${builtins.getEnv \"HOME\"}"],
          [T.replicate 201 "x"],
          replicate 33 "curl"
        ]
        $ \attributes ->
          validAttributes attributes `shouldBe` False
  describe "runtime wire protocol" $ do
    it "rejects socket descriptors before privileged code can write credentials to them" $
      socketPair $ \client server -> do
        Socket.withFdSocket client (Socket.sendFd client)
        withRuntimeStreams server (const (pure ())) `shouldThrow` anyIOException
    it "requires pipes even when the caller passes an open regular file" $
      withSystemTempDirectory "max-runtime-fd" $ \directory ->
        withBinaryFile (directory </> "file") ReadWriteMode $ \handle ->
          socketPair $ \client server -> do
            bracket (hDuplicate handle >>= handleToFd) closeFd (Socket.sendFd client . fromIntegral)
            withRuntimeStreams server (const (pure ())) `shouldThrow` anyIOException
    it "round-trips typed requests without shell interpretation" $ do
      let request = RunCommand "max-sb-1-s1" ["sh", "-c", "printf '%s' '$HOME; x'", "\n"]
      eitherDecode (encode (runtimeProtocolVersion, request)) `shouldBe` Right (runtimeProtocolVersion, request)
    it "rejects a frame length before reading or allocating its payload" $
      socketPair $ \client server -> do
        SocketIO.sendAll client (BS.pack [255, 255, 255, 255])
        receiveFrame @RuntimeRequest 262144 server `shouldThrow` anyIOException
    it "rejects a disconnected peer with a partial frame" $
      socketPair $ \client server -> do
        SocketIO.sendAll client (BS.pack [0, 0])
        Socket.shutdown client Socket.ShutdownSend
        receiveFrame @RuntimeResponse 8192 server `shouldThrow` anyIOException
    it "streams through caller-opened descriptors and preserves a nonzero operation result" $
      replicateM_ 32 $
        withSystemTempDirectory "max-runtime-wire" $ \directory -> do
          -- Keep sockaddr_un under the macOS limit, even with a long TMPDIR.
          let path = directory </> "s"
          bracket (Socket.socket Socket.AF_UNIX Socket.Stream Socket.defaultProtocol) Socket.close $ \listener -> do
            Socket.bind listener (Socket.SockAddrUnix path)
            Socket.listen listener 1
            pipe $ \input inputWriter -> pipe $ \outputReader output -> pipe $ \errorsReader errors -> do
              BS.hPut inputWriter "fixture input"
              hFlush inputWriter
              let server = bracket (fst <$> Socket.accept listener) Socket.close $ \connection ->
                    withRuntimeStreams connection $ \(remoteInput, remoteOutput, remoteErrors) -> do
                      (version, request) <- receiveFrame @(Int, RuntimeRequest) 262144 connection
                      version `shouldBe` runtimeProtocolVersion
                      request `shouldBe` RunCommand "max-sb-1-s1" ["cat"]
                      BS.hGet remoteInput 13 >>= BS.hPut remoteOutput
                      BS.hPut remoteErrors "fixture error"
                      hFlush remoteOutput
                      hFlush remoteErrors
                      sendFrame connection (RuntimeResponse runtimeProtocolVersion 42 Nothing)
              (response, ()) <-
                concurrently
                  (requestRuntime path (RunCommand "max-sb-1-s1" ["cat"]) (input, output, errors))
                  server
              response.exitCode `shouldBe` 42
              BS.hGet outputReader 13 `shouldReturn` "fixture input"
              BS.hGet errorsReader 13 `shouldReturn` "fixture error"
  where
    pipe action =
      bracket
        (createPipe >>= \(reader, writer) -> (,) <$> fdToHandle reader <*> fdToHandle writer)
        (\(reader, writer) -> hClose reader >> hClose writer)
        (uncurry action)
    socketPair action =
      bracket
        (Socket.socketPair Socket.AF_UNIX Socket.Stream Socket.defaultProtocol)
        (\(left, right) -> Socket.close left >> Socket.close right)
        (uncurry action)
