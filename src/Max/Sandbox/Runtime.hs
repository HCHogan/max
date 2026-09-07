-- | Native sandbox operations through the restricted systemd runtime broker.
-- PostgreSQL owns lifecycle metadata; host directories own /work. Execution
-- streams remain bounded and commands run as the guest sandbox user.
module Max.Sandbox.Runtime
  ( -- * Lifecycle
    runRun,
    runRm,
    runVolumeRm,
    RuntimePresence (..),
    RuntimeContainerStatus (..),
    inspectContainerStatus,
    inspectContainerPolicy,
    inspectVolumePresence,
    listContainersByPrefix,
    listVolumesByPrefix,

    -- * Exec
    ExecResult (..),
    SandboxManifest (..),
    runExec,
    runPreparePackages,
    runSearch,
    runRead,
    runWrite,

    -- * Copy
    runCopyToContainer,
    runCopyFromContainer,
    readSandboxArtifact,
    readBoundedArtifact,

    -- * Tuning knobs
    maxOutputBytes,
    maxSpillBytes,
    sandboxNetwork,

    -- * Helpers
    shellQuote,
    wrapPackages,
    stripAnsi,
  )
where

import Control.Concurrent (forkFinally, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, SomeException, bracket, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Max.Runtime.Protocol (sandboxPolicyVersion)
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (..))
import System.IO (Handle, hClose, hFlush, hSetBinaryMode, openBinaryTempFile)
import System.Process
  ( CreateProcess (..),
    StdStream (..),
    proc,
    readCreateProcessWithExitCode,
    readProcessWithExitCode,
    waitForProcess,
    withCreateProcess,
  )
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | Per-call stdout/stderr cap (bytes).  Anything past this is
-- dropped; the caller sees a 'truncated' flag.
maxOutputBytes :: Int
maxOutputBytes = 16 * 1024

-- | Per-stream spill cap.  The reader continues draining and hashing after
-- this point, but does not retain any more bytes on the host.  This keeps both
-- memory and temporary-disk use finite even for an adversarial command.
maxSpillBytes :: Int
maxSpillBytes = 8 * 1024 * 1024

-- Provisioned with public-only egress by the NixOS sandbox-network module.
-- A missing network is an error; the broker never falls back to host networking.
sandboxNetwork :: Text
sandboxNetwork = "max-sandbox"

-- | Result of one in-container exec.
data ExecResult = ExecResult
  { erExitCode :: !Int,
    erStdout :: !Text,
    erStderr :: !Text,
    erTruncated :: !Bool,
    -- | When truncated: container-side path holding the full
    -- stdout+stderr up to 'maxSpillBytes' per stream, for the model to
    -- grep/head on demand.
    erSpillPath :: !(Maybe Text),
    -- | True when output exceeded the bounded spill as well as the preview.
    erSpillTruncated :: !Bool,
    erDurationMillis :: !Int,
    erActualCommand :: !Text,
    erNetworkMode :: !Text,
    erStdoutSha256 :: !Text,
    erStdoutBytes :: !Int,
    erStderrSha256 :: !Text,
    erStderrBytes :: !Int,
    -- | Post-effect observation of /work.  This is journal evidence, not a
    -- reconstruction mechanism; the named volume remains the durable state.
    erObservedManifest :: !(Maybe SandboxManifest)
  }
  deriving stock (Show)

data SandboxManifest = SandboxManifest
  { smSha256 :: !Text,
    smFileCount :: !Int,
    smPreview :: !Text,
    smTruncated :: !Bool,
    smChangedPaths :: ![Text],
    smChangedPathsTruncated :: !Bool,
    smContainerDiff :: ![Text],
    smContainerDiffTruncated :: !Bool
  }
  deriving stock (Show)

-- | A negative runtime inspection is useful only when the broker positively
-- reports that the resource is absent.  Treating CLI/daemon failure as
-- absence would let a transient outage turn durable metadata into data loss.
data RuntimePresence
  = RuntimePresent
  | RuntimeAbsent
  | RuntimeUnavailable !Text
  deriving stock (Show, Eq)

data RuntimeContainerStatus
  = RuntimeContainerRunning
  | RuntimeContainerStopped
  | RuntimeContainerMissing
  | RuntimeContainerUnavailable !Text
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- Lifecycle.

-- | Start a template instance around a durable /work directory. The broker
-- chooses the prebuilt NixOS guest and enforces its isolation policy.
runRun ::
  -- | container name
  Text ->
  -- | image
  Text ->
  -- | volume name (mounted at /work)
  Text ->
  -- | operator-provisioned network
  Text ->
  IO (Either Text Text)
runRun name profile volume network = do
  result <- try @IOException $ readProcessWithExitCode "max-runtime"
    ["create", T.unpack name, T.unpack profile, T.unpack volume, T.unpack network] ""
  pure $ case result of
    Left err -> Left ("sandbox startup failed: " <> T.pack (show err))
    Right (ExitSuccess, out, _) -> Right (T.strip (T.pack out))
    Right (ExitFailure code, _, err) -> Left ("sandbox startup exited " <> T.pack (show code) <> ": " <> T.strip (T.pack err))

-- | Stop only the instance. Its persistent work directory survives.
runRm :: Text -> IO ()
runRm name = do
  _ <- try @IOException $ readProcessWithExitCode "max-runtime" ["remove", T.unpack name] ""
  pure ()

-- | Removal is confirmed by the registry before durable state is settled.
runVolumeRm :: Text -> IO ()
runVolumeRm name = do
  _ <- try @IOException $ readProcessWithExitCode "max-runtime" ["volume-remove", T.unpack name] ""
  pure ()

-- | Names (not opaque container ids) in Max's owned namespace.
listContainersByPrefix :: Text -> IO [Text]
listContainersByPrefix prefix = do
  res <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        ["list", T.unpack prefix]
        ""
  pure $ case res of
    Right (ExitSuccess, out, _) ->
      filter (not . T.null) (T.lines (T.pack out))
    _ -> []

inspectContainerStatus :: Text -> IO RuntimeContainerStatus
inspectContainerStatus name = do
  result <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        ["status", T.unpack name]
        ""
  pure $ case result of
    Left err -> RuntimeContainerUnavailable (runtimeIOException err)
    Right (ExitSuccess, out, _)
      | T.strip (T.pack out) == "running" -> RuntimeContainerRunning
      | otherwise -> RuntimeContainerStopped
    Right (ExitFailure code, out, err)
      | code == 3 -> RuntimeContainerMissing
      | otherwise -> RuntimeContainerUnavailable (runtimeFailure code detail)
      where
        detail = T.strip (T.pack (out <> "\n" <> err))

-- | Whether a running/stopped container was created under the current
-- isolation contract.  Inspection failure is deliberately false: adopting an
-- unverifiable shell would weaken a write-capable boundary.
inspectContainerPolicy :: Text -> IO Bool
inspectContainerPolicy name = do
  result <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        ["policy", T.unpack name]
        ""
  pure $ case result of
    Right (ExitSuccess, out, _) -> T.words (T.pack out) == [sandboxPolicyVersion, sandboxNetwork, "1"]
    _ -> False

-- | List durable work directories in the requested Max namespace.
listVolumesByPrefix :: Text -> IO [Text]
listVolumesByPrefix prefix = do
  res <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        ["volumes", T.unpack prefix]
        ""
  pure $ case res of
    Right (ExitSuccess, out, _) ->
      filter (not . T.null) (T.lines (T.pack out))
    _ -> []

inspectVolumePresence :: Text -> IO RuntimePresence
inspectVolumePresence name = do
  result <- try @IOException $ readProcessWithExitCode "max-runtime" ["volume-status", T.unpack name] ""
  pure $ case result of
    Left err -> RuntimeUnavailable (runtimeIOException err)
    Right (ExitSuccess, _, _) -> RuntimePresent
    Right (ExitFailure code, out, err)
      | code == 3 -> RuntimeAbsent
      | otherwise -> RuntimeUnavailable (runtimeFailure code detail)
      where
        detail = T.strip (T.pack (out <> "\n" <> err))

runtimeIOException :: IOException -> Text
runtimeIOException err = "runtime inspection failed: " <> T.take 1000 (T.pack (show err))

runtimeFailure :: Int -> Text -> Text
runtimeFailure code detail =
  "runtime inspection exited " <> T.pack (show code) <> ": " <> T.take 1000 detail

--------------------------------------------------------------------------------
-- Exec.

-- | Run @cmd@ inside @container@ with a hard wallclock cap, capturing
-- stdout/stderr.  Wraps the user command in @timeout SECONDS sh -c
-- '...'@ so the kill happens inside the container; we then just wait
-- for @sandbox exec@ to return.
runExec ::
  -- | container name
  Text ->
  -- | host-observed network mode
  Text ->
  -- | shell command (passed to @sh -c@)
  Text ->
  -- | timeout seconds
  Int ->
  IO ExecResult
runExec container networkMode cmd timeoutSecs = do
  started <- getPOSIXTime
  let stamp = (show :: Int -> String) (round (started * 1000000))
      marker = "/tmp/max-observe-" <> T.pack stamp
  _ <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        ["exec", T.unpack container, "sh", "-c", T.unpack ("touch " <> shellQuote marker)]
        ""
  let wrapped =
        "timeout --signal=TERM --kill-after=5s --preserve-status "
          <> T.pack (show timeoutSecs)
          <> " sh -c "
          <> shellQuote cmd
      args =
        [ "exec",
          "--workdir",
          "/work",
          T.unpack container,
          "sh",
          "-c",
          T.unpack wrapped
        ]
  base <-
    withCaptureFile "max-sandbox-stdout" $ \outPath outTemp ->
      withCaptureFile "max-sandbox-stderr" $ \errPath errTemp -> do
        let process =
              (proc "max-runtime" args)
                { std_in = CreatePipe,
                  std_out = CreatePipe,
                  std_err = CreatePipe
                }
        processResult <-
          try @IOException $
            withCreateProcess process $ \maybeInput maybeOutput maybeErrors processHandle ->
              case (maybeInput, maybeOutput, maybeErrors) of
                (Just input, Just output, Just errors) -> do
                  hClose input
                  outDone <- newEmptyMVar
                  errDone <- newEmptyMVar
                  _ <- forkFinally (captureStream output outTemp) (putMVar outDone)
                  _ <- forkFinally (captureStream errors errTemp) (putMVar errDone)
                  code <- waitForProcess processHandle
                  outResult <- takeMVar outDone
                  errResult <- takeMVar errDone
                  case (outResult, errResult) of
                    (Right capturedOut, Right capturedErr) -> do
                      hFlush outTemp
                      hFlush errTemp
                      let truncated = capturedOut.csBytes > maxOutputBytes || capturedErr.csBytes > maxOutputBytes
                          spillTruncated = capturedOut.csSpillTruncated || capturedErr.csSpillTruncated
                      spill <-
                        if truncated
                          then spillOutputFiles container (T.pack stamp) outPath errPath capturedOut capturedErr
                          else pure Nothing
                      pure
                        ExecResult
                          { erExitCode = case code of ExitSuccess -> 0; ExitFailure c -> c,
                            erStdout = capturedOut.csPreview,
                            erStderr = capturedErr.csPreview,
                            erTruncated = truncated,
                            erSpillPath = spill,
                            erSpillTruncated = spillTruncated,
                            erDurationMillis = 0,
                            erActualCommand = cmd,
                            erNetworkMode = networkMode,
                            erStdoutSha256 = capturedOut.csSha256,
                            erStdoutBytes = capturedOut.csBytes,
                            erStderrSha256 = capturedErr.csSha256,
                            erStderrBytes = capturedErr.csBytes,
                            erObservedManifest = Nothing
                          }
                    captureFailure ->
                      pure (streamCaptureFailure cmd networkMode captureFailure)
                _ ->
                  pure
                    ( runtimeExecFailure
                        cmd
                        networkMode
                        (userError "sandbox exec did not expose all requested pipes")
                    )
        case processResult of
          Left e -> pure (runtimeExecFailure cmd networkMode e)
          Right result -> pure result
  finished <- getPOSIXTime
  manifest <- observeManifest container marker
  pure
    base
      { erDurationMillis = max 0 (round ((finished - started) * 1000)),
        erObservedManifest = manifest
      }

-- | Realise allowlisted-by-construction nixpkgs attributes in a short-lived
-- helper.  This is the only sandbox-related process with a writable shared
-- Nix store.  The model controls only attribute arguments;
-- it cannot supply a shell command, image, mount, or network mode.  The actual
-- user command subsequently runs in the non-root, public-egress sandbox.
runPreparePackages :: Text -> [Text] -> Int -> IO (Either Text [Text])
runPreparePackages _ [] _ = pure (Right [])
runPreparePackages container packages timeoutSecs = do
  result <- try @IOException $ readProcessWithExitCode "max-runtime"
    (["build", T.unpack container, show timeoutSecs] <> map T.unpack packages) ""
  pure $ case result of
    Left err -> Left ("package preparation failed: " <> T.pack (show err))
    Right (ExitSuccess, out, _) ->
      let paths = filter (not . T.null) (map T.strip (T.lines (T.pack out)))
       in if not (null paths) && all validPreparedStorePath paths
            then Right paths
            else Left "package preparation returned an invalid or empty store-path list"
    Right (ExitFailure code, out, err) -> Left $
      "package preparation exited " <> T.pack (show code) <> ": "
        <> T.takeEnd 4000 (stripAnsi (T.pack (out <> "\n" <> err)))

-- | Search the same host-owned nixpkgs pin used by package preparation.
runSearch :: Text -> Text -> IO (Either Text Text)
runSearch container query = do
  result <- try @IOException $ readProcessWithExitCode "max-runtime" ["search", T.unpack container, T.unpack query] ""
  pure $ case result of
    Left err -> Left ("package search failed: " <> T.pack (show err))
    Right (ExitSuccess, out, _) -> Right (T.pack out)
    Right (ExitFailure code, _, err) -> Left ("package search exited " <> T.pack (show code) <> ": " <> T.takeEnd 4000 (T.pack err))

validPreparedStorePath :: Text -> Bool
validPreparedStorePath path =
  case T.stripPrefix "/nix/store/" path of
    Nothing -> False
    Just name -> not (T.null name) && not (T.any (\c -> c == '/' || isSpace c) name)

data CapturedStream = CapturedStream
  { csPreview :: !Text,
    csSha256 :: !Text,
    csBytes :: !Int,
    csSpillTruncated :: !Bool
  }

captureStream :: Handle -> Handle -> IO CapturedStream
captureStream source spill = do
  hSetBinaryMode source True
  hSetBinaryMode spill True
  go SHA256.init 0 BS.empty 0
  where
    go digest total preview retained = do
      chunk <- BS.hGetSome source (32 * 1024)
      if BS.null chunk
        then do
          hClose source
          let truncated = total > maxOutputBytes
              previewText = stripAnsi (TE.decodeUtf8With lenientDecode preview)
          pure
            CapturedStream
              { csPreview = previewText <> if truncated then "\n…(truncated)" else "",
                csSha256 = TE.decodeUtf8 (Base16.encode (SHA256.finalize digest)),
                csBytes = total,
                csSpillTruncated = total > maxSpillBytes
              }
        else do
          let previewRoom = max 0 (maxOutputBytes - BS.length preview)
              spillRoom = max 0 (maxSpillBytes - retained)
              preview' = preview <> BS.take previewRoom chunk
              spillChunk = BS.take spillRoom chunk
          BS.hPut spill spillChunk
          go
            (SHA256.update digest chunk)
            (total + BS.length chunk)
            preview'
            (retained + BS.length spillChunk)

withCaptureFile :: String -> (FilePath -> Handle -> IO a) -> IO a
withCaptureFile template = bracket acquire release . uncurry
  where
    acquire = do
      tempDir <- getTemporaryDirectory
      openBinaryTempFile tempDir template
    release (path, handle) = do
      _ <- try @IOException (hClose handle)
      _ <- try @IOException (removeFile path)
      pure ()

runtimeExecFailure :: Text -> Text -> IOException -> ExecResult
runtimeExecFailure cmd networkMode err =
  let detail = "sandbox exec failed: " <> T.pack (show err)
   in ExecResult
        { erExitCode = -1,
          erStdout = "",
          erStderr = detail,
          erTruncated = False,
          erSpillPath = Nothing,
          erSpillTruncated = False,
          erDurationMillis = 0,
          erActualCommand = cmd,
          erNetworkMode = networkMode,
          erStdoutSha256 = digestText "",
          erStdoutBytes = 0,
          erStderrSha256 = digestText detail,
          erStderrBytes = textBytes detail,
          erObservedManifest = Nothing
        }

streamCaptureFailure ::
  Text ->
  Text ->
  (Either SomeException CapturedStream, Either SomeException CapturedStream) ->
  ExecResult
streamCaptureFailure cmd networkMode failures =
  runtimeExecFailure cmd networkMode (userError (captureFailureMessage failures))
  where
    captureFailureMessage (outcome, errcome) =
      "stream capture failed: stdout=" <> render outcome <> "; stderr=" <> render errcome
    render = either show (const "ok")

-- | Hash and preview the observed /work manifest without streaming an
-- unbounded directory listing through the host process.  The temporary file
-- lives outside /work, so the observation does not change the state it names.
observeManifest :: Text -> Text -> IO (Maybe SandboxManifest)
observeManifest container marker = do
  let script =
        "tmp=$(mktemp /tmp/max-manifest.XXXXXX) || exit 1; "
          <> "find /work -xdev -type f -printf '%P\\t%s\\t%T@\\n' 2>/dev/null | LC_ALL=C sort >\"$tmp\"; "
          <> "sha256sum \"$tmp\" | cut -d' ' -f1; "
          <> "wc -l <\"$tmp\"; head -n 200 \"$tmp\"; rm -f \"$tmp\""
  result <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        ["exec", "--workdir", "/work", T.unpack container, "sh", "-c", T.unpack script]
        ""
  changed <- observeChangedPaths container marker
  _ <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        ["exec", T.unpack container, "sh", "-c", T.unpack ("rm -f " <> shellQuote marker)]
        ""
  pure $ case result of
    Right (ExitSuccess, out, _) -> case T.lines (T.pack out) of
      sha : countText : previewLines
        | T.length (T.strip sha) == 64,
          Just count <- readMaybe (T.unpack (T.strip countText)) ->
            Just
              SandboxManifest
                { smSha256 = T.strip sha,
                  smFileCount = count,
                  smPreview = T.intercalate "\n" previewLines,
                  smTruncated = count > length previewLines,
                  smChangedPaths = fst changed,
                  smChangedPathsTruncated = snd changed,
                  smContainerDiff = [],
                  smContainerDiffTruncated = False
                }
      _ -> Nothing
    _ -> Nothing

observeChangedPaths :: Text -> Text -> IO ([Text], Bool)
observeChangedPaths container marker = do
  let script =
        "find /work -xdev -newer "
          <> shellQuote marker
          <> " -printf '%P\\t%y\\t%s\\t%T@\\n' 2>/dev/null | LC_ALL=C sort | head -n 201"
  result <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        ["exec", "--workdir", "/work", T.unpack container, "sh", "-c", T.unpack script]
        ""
  pure $ case result of
    Right (ExitSuccess, out, _) -> boundedLines 200 (T.lines (T.pack out))
    _ -> ([], False)

boundedLines :: Int -> [a] -> ([a], Bool)
boundedLines limit values = (take limit values, length values > limit)

digestText :: Text -> Text
digestText = TE.decodeUtf8 . Base16.encode . SHA256.hash . TE.encodeUtf8

textBytes :: Text -> Int
textBytes = BS.length . TE.encodeUtf8

-- | Copy the bounded host-side captures back into the sandbox and assemble a
-- readable combined spill.  @sandbox copy@ streams from disk, so this does not
-- re-materialise the retained output in the Max heap.
spillOutputFiles ::
  Text ->
  Text ->
  FilePath ->
  FilePath ->
  CapturedStream ->
  CapturedStream ->
  IO (Maybe Text)
spillOutputFiles container stamp stdoutPath stderrPath capturedOut capturedErr = do
  let path = "/work/.max-out/exec-" <> stamp <> ".log"
      stagedOut = path <> ".stdout"
      stagedErr = path <> ".stderr"
      copy host target =
        try @IOException $
          readProcessWithExitCode
            "max-runtime"
            ["copy-to", T.unpack container, host, T.unpack target]
            ""
  created <- runtimeExecSmall container "mkdir -p /work/.max-out"
  copiedOut <- if created then copy stdoutPath stagedOut else pure (Left (userError "spill directory unavailable"))
  copiedErr <- case copiedOut of
    Right (ExitSuccess, _, _) -> copy stderrPath stagedErr
    _ -> pure (Left (userError "stdout spill copy failed"))
  assembled <- case copiedErr of
    Right (ExitSuccess, _, _) ->
      runtimeExecSmall container (assembleSpill path stagedOut stagedErr capturedOut capturedErr)
    _ -> pure False
  if assembled
    then pure (Just path)
    else do
      _ <- runtimeExecSmall container ("rm -f " <> shellQuote stagedOut <> " " <> shellQuote stagedErr <> " " <> shellQuote path)
      pure Nothing

assembleSpill :: Text -> Text -> Text -> CapturedStream -> CapturedStream -> Text
assembleSpill path stagedOut stagedErr capturedOut capturedErr =
  "{ printf '%s\\n' '### stdout'; cat "
    <> shellQuote stagedOut
    <> spillMarker capturedOut
    <> "; printf '%s\\n' '### stderr'; cat "
    <> shellQuote stagedErr
    <> spillMarker capturedErr
    <> "; } > "
    <> shellQuote path
    <> " && rm -f "
    <> shellQuote stagedOut
    <> " "
    <> shellQuote stagedErr
  where
    spillMarker captured
      | captured.csSpillTruncated =
          "; printf '\\n…(spill truncated at %s bytes)\\n' '" <> T.pack (show maxSpillBytes) <> "'"
      | otherwise = "; printf '\\n'"

runtimeExecSmall :: Text -> Text -> IO Bool
runtimeExecSmall container command = do
  result <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        ["exec", T.unpack container, "sh", "-c", T.unpack command]
        ""
  pure $ case result of
    Right (ExitSuccess, _, _) -> True
    _ -> False

-- | Read a file from the container, capped at 'maxOutputBytes'.
--
-- > sh -c "head -c <max> /work/<path>"
runRead ::
  -- | container name
  Text ->
  -- | path (relative to /work, or absolute)
  Text ->
  -- | cap bytes
  Int ->
  IO (Either Text Text)
runRead container path maxBytes = do
  let cmd =
        "head -c "
          <> T.pack (show maxBytes)
          <> " "
          <> shellQuote path
      args =
        [ "exec",
          "--workdir",
          "/work",
          T.unpack container,
          "sh",
          "-c",
          T.unpack cmd
        ]
  res <- try @IOException $ readProcessWithExitCode "max-runtime" args ""
  pure $ case res of
    Left e -> Left ("sandbox exec failed: " <> T.pack (show e))
    Right (ExitSuccess, out, _) -> Right (T.pack out)
    Right (ExitFailure c, _, err) ->
      Left $
        "read failed (exit "
          <> T.pack (show c)
          <> "): "
          <> T.strip (T.pack err)

-- | Write @content@ to a file inside the container, overwriting if
-- present.  Uses @sandbox exec -i ... tee@ with content fed via stdin
-- so we don't have to shell-quote arbitrary bytes.
runWrite ::
  -- | container name
  Text ->
  -- | path
  Text ->
  -- | content
  Text ->
  IO (Either Text ())
runWrite container path content = do
  -- mkdir -p the parent first (cheap, handles "subdir/file.py")
  let parent = T.dropWhileEnd (/= '/') path
      mkParent =
        if T.null parent
          then ""
          else "mkdir -p " <> shellQuote (T.dropEnd 1 parent) <> " && "
      cmd =
        mkParent <> "cat > " <> shellQuote path
      args =
        [ "exec",
          "-i",
          "--workdir",
          "/work",
          T.unpack container,
          "sh",
          "-c",
          T.unpack cmd
        ]
      proc' = (proc "max-runtime" args) {std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
  res <- try @IOException $ readCreateProcessWithExitCode proc' (T.unpack content)
  pure $ case res of
    Left e -> Left ("sandbox exec failed: " <> T.pack (show e))
    Right (ExitSuccess, _, _) -> Right ()
    Right (ExitFailure c, _, err) ->
      Left $
        "write failed (exit "
          <> T.pack (show c)
          <> "): "
          <> T.strip (T.pack err)

--------------------------------------------------------------------------------
-- Copy in/out.

-- | @sandbox copy HOST_PATH CONTAINER:CONTAINER_PATH@.  Used by
-- @import_file_to_sandbox@ to materialise a host-side blob inside
-- the sandbox at /work/<path>.
runCopyToContainer ::
  -- | container name
  Text ->
  -- | host path
  FilePath ->
  -- | container path
  Text ->
  IO (Either Text ())
runCopyToContainer container hostPath containerPath = do
  res <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        [ "copy-to", T.unpack container, hostPath, T.unpack containerPath ]
        ""
  pure $ case res of
    Left e -> Left ("sandbox copy failed: " <> T.pack (show e))
    Right (ExitSuccess, _, _) -> Right ()
    Right (ExitFailure c, _, err) ->
      Left $
        "sandbox copy exited "
          <> T.pack (show c)
          <> ": "
          <> T.strip (T.pack err)

-- | Read bytes directly from the container with a bound at both ends. No
-- unbounded host staging file or readFile allocation precedes validation.
readSandboxArtifact :: Text -> Text -> IO (Either Text BS.ByteString)
readSandboxArtifact container path = do
  result <- try @IOException
    $ timeout (35 * 1_000_000)
    $ withCreateProcess
      ( proc
          "max-runtime"
          [ "exec",
            "--workdir",
            "/work",
            T.unpack container,
            "timeout",
            "30",
            "head",
            "-c",
            show (artifactLimit + 1),
            "--",
            T.unpack path
          ]
      )
        { std_out = CreatePipe,
          std_err = NoStream
        }
    $ \_ output _ process ->
      case output of
        Nothing -> pure (Left "sandbox artifact stream unavailable")
        Just handle -> do
          bytes <- readBoundedArtifact artifactLimit handle
          status <- waitForProcess process
          pure $ case status of
            ExitSuccess -> bytes
            ExitFailure code -> Left ("sandbox artifact read failed: " <> T.pack (show code))
  pure $ case result of
    Left err -> Left (T.pack (show err))
    Right Nothing -> Left "sandbox artifact read timed out"
    Right (Just value) -> value
  where
    artifactLimit = 64 * 1024 * 1024

-- | Retain at most limit+1 bytes; the extra byte distinguishes an exact fit.
readBoundedArtifact :: Int -> Handle -> IO (Either Text BS.ByteString)
readBoundedArtifact limit handle = do
  bytes <- BS.hGet handle (max 0 limit + 1)
  pure $
    if BS.length bytes > max 0 limit
      then Left "sandbox artifact exceeds byte limit"
      else Right bytes

-- | @sandbox copy CONTAINER:CONTAINER_PATH HOST_PATH@.  Used by
-- @send_image_from_sandbox@ / @send_file_from_sandbox@ to materialise
-- a sandbox artifact onto the host so we can read or stage it.
runCopyFromContainer ::
  Text -> -- container name
  Text -> -- container path
  FilePath -> -- host path (destination file or dir)
  IO (Either Text ())
runCopyFromContainer container containerPath hostPath = do
  res <-
    try @IOException $
      readProcessWithExitCode
        "max-runtime"
        [ "copy-from", T.unpack container, T.unpack containerPath, hostPath ]
        ""
  pure $ case res of
    Left e -> Left ("sandbox copy failed: " <> T.pack (show e))
    Right (ExitSuccess, _, _) -> Right ()
    Right (ExitFailure c, _, err) ->
      Left $
        "sandbox copy exited "
          <> T.pack (show c)
          <> ": "
          <> T.strip (T.pack err)

--------------------------------------------------------------------------------
-- Helpers.

-- | Quote a string for @sh -c@.  Wraps in single quotes; any
-- internal single quotes are escaped via the @'\''@ trick.
shellQuote :: Text -> Text
shellQuote t = "'" <> T.replace "'" "'\\''" t <> "'"

-- | Strip terminal control noise from captured output: ANSI escape
-- sequences (CSI colour/cursor codes like @ESC[101m@ / @ESC[25C@, OSC
-- strings, and lone two-char escapes) plus leftover C0 control bytes
-- (carriage returns, bells, backspaces).  TUI programs (fastfetch,
-- eza --color) emit these for a real terminal; in a QQ message they
-- are garbage.  Newlines and tabs are kept.
stripAnsi :: Text -> Text
stripAnsi = T.filter keep . T.pack . go . T.unpack
  where
    keep c = c == '\n' || c == '\t' || c >= ' '

    go [] = []
    go ('\ESC' : rest) = case rest of
      ('[' : cs) -> go (dropCsi cs) -- CSI: … <final 0x40–0x7E>
      (']' : cs) -> go (dropOsc cs) -- OSC: … <BEL | ESC \>
      (_ : cs) -> go cs -- other 2-byte escape
      [] -> []
    go (c : cs) = c : go cs

    dropCsi [] = []
    dropCsi (c : cs)
      | c >= '\x40' && c <= '\x7E' = cs
      | otherwise = dropCsi cs

    dropOsc [] = []
    dropOsc ('\BEL' : cs) = cs
    dropOsc ('\ESC' : '\\' : cs) = cs
    dropOsc (_ : cs) = dropOsc cs

-- | Put already-realised Nix store paths on PATH for one command.  Nothing is
-- installed into the sandbox itself.  Empty list = run the command as-is.
--
-- Package realisation is performed separately by 'runPreparePackages', in a
-- fixed helper with narrowly scoped package authority.  The unprivileged,
-- non-root sandbox therefore never needs write access to the shared Nix DB.
-- A bare @python3Packages.*@ derivation does not alter Python's import path, so
-- The broker collects those attributes into one
-- @python3.withPackages@ environment.  Every attribute segment is quoted and
-- validated by the registry before this expression is built.
wrapPackages :: [Text] -> Text -> Text
wrapPackages [] cmd = cmd
wrapPackages storePaths cmd =
  "export PATH="
    <> shellQuote (T.intercalate ":" (map (<> "/bin") storePaths))
    <> ":\"$PATH\"; exec sh -c "
    <> shellQuote cmd
