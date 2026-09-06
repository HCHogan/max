-- |
-- Thin @docker@ CLI wrappers via 'System.Process'.  We shell out
-- rather than talk the HTTP API because (a) the CLI is already
-- installed wherever 'docker run' works, (b) error messages are
-- familiar to humans reading logs, and (c) it's ~200 lines less
-- code.
--
-- == Output limits
--
-- 'runExec' drains @stdout@/@stderr@ concurrently and incrementally, so a
-- noisy command cannot make the Max process retain an unbounded 'String'.
-- The model-facing preview is capped at 'maxOutputBytes' per stream and a
-- best-effort spill is capped at 'maxSpillBytes' per stream.  Per-call
-- wallclock deadline is enforced *inside the container* via @timeout(1)@ so
-- runaway processes are killed where they live rather than leaving us a
-- dangling 'docker exec' to wrestle with.
module Max.Sandbox.Docker
  ( -- * Lifecycle
    runRun,
    runRm,
    runVolumeRm,
    DockerPresence (..),
    DockerContainerStatus (..),
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
    nixVolume,

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
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock.POSIX (getPOSIXTime)
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

-- | Shared nix store volume, mounted at /nix in every sandbox so a
-- package downloaded once is instant for all later sandboxes.  On
-- the first ever run docker seeds it from the image's /nix.
-- Deliberately outside the @max-sb-@ namespace so the startup reaper
-- never touches it; it survives bot restarts by design.
nixVolume :: Text
nixVolume = "max-nix"

-- | A named volume's root mount ownership is reset by some Docker backends.
-- Mount a persistent child directory as /work so uid/mode changes survive
-- across helper and long-lived container mount namespaces.
workVolumeSubpath :: Text
workVolumeSubpath = ".max-work"

-- | Bump whenever the @docker run@ isolation contract changes.  Reconciliation
-- rebuilds an older container around its durable /work volume before adopting
-- it, so a long-lived shell cannot silently retain weaker limits.
sandboxPolicyVersion :: Text
sandboxPolicyVersion = "4"

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

-- | A negative Docker inspection is useful only when the daemon positively
-- reports that the resource is absent.  Treating CLI/daemon failure as
-- absence would let a transient outage turn durable metadata into data loss.
data DockerPresence
  = DockerPresent
  | DockerAbsent
  | DockerUnavailable !Text
  deriving stock (Show, Eq)

data DockerContainerStatus
  = DockerContainerRunning
  | DockerContainerStopped
  | DockerContainerMissing
  | DockerContainerUnavailable !Text
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- Lifecycle.

-- | @docker run -d --init --name NAME [...args] IMAGE sleep infinity@.
-- Mounts the per-sandbox work volume at /work and the shared 'nixVolume' at
-- /nix.  The shell is non-root, has no network/capabilities, and receives hard
-- resource limits.  The root filesystem is read-only; /work, /tmp and the
-- unprivileged home are the only writable locations.
-- Returns the container id on success, or a stderr-flavoured error.
runRun ::
  -- | container name
  Text ->
  -- | image
  Text ->
  -- | volume name (mounted at /work)
  Text ->
  -- | network mode ("bridge" / "none")
  Text ->
  IO (Either Text Text)
runRun name image volume network = do
  prepared <- prepareWorkVolume image volume
  if not prepared
    then pure (Left "docker could not prepare the sandbox work volume")
    else do
      let args =
            [ "run",
              "-d",
              "--init",
              "--name",
              T.unpack name,
              "--label",
              "max.sandbox.policy=" <> T.unpack sandboxPolicyVersion,
              "--network",
              T.unpack network,
              "--user",
              "1000:1000",
              "--cap-drop",
              "ALL",
              "--security-opt",
              "no-new-privileges",
              "--memory",
              "4g",
              "--memory-swap",
              "4g",
              "--cpus",
              "2",
              "--pids-limit",
              "512",
              "--read-only",
              "--tmpfs",
              "/tmp:rw,nosuid,nodev,size=512m,mode=1777",
              "--tmpfs",
              "/home/sandbox:rw,nosuid,nodev,size=256m,uid=1000,gid=1000,mode=700",
              "-v",
              T.unpack nixVolume <> ":/nix",
              "--mount",
              "type=volume,src="
                <> T.unpack volume
                <> ",dst=/work,volume-subpath="
                <> T.unpack workVolumeSubpath
                <> ",volume-nocopy",
              "-w",
              "/work",
              T.unpack image,
              "sleep",
              "infinity"
            ]
      res <- try @IOException $ readProcessWithExitCode "docker" args ""
      pure $ case res of
        Left e -> Left ("docker run failed: " <> T.pack (show e))
        Right (ExitSuccess, out, _) -> Right (T.strip (T.pack out))
        Right (ExitFailure c, _, err) ->
          Left $
            "docker run exited "
              <> T.pack (show c)
              <> ": "
              <> T.strip (T.pack err)

-- | A named volume's root is root-owned, and on some Docker backends changes
-- to that mount root do not survive the next mount namespace.  Prepare a child
-- directory that can be mounted as /work instead.  Existing root-level files
-- are migrated into it so adopting an older durable volume does not hide data.
-- No user-controlled command is involved here.
prepareWorkVolume :: Text -> Text -> IO Bool
prepareWorkVolume image volume = do
  result <-
    try @IOException $
      readProcessWithExitCode
        "docker"
        [ "run",
          "--rm",
          "--network",
          "none",
          "--user",
          "0:0",
          "--cap-drop",
          "ALL",
          "--cap-add",
          "CHOWN",
          "--security-opt",
          "no-new-privileges",
          "--memory",
          "512m",
          "--memory-swap",
          "512m",
          "--cpus",
          "1",
          "--pids-limit",
          "64",
          "--read-only",
          "-v",
          T.unpack volume <> ":/volume",
          T.unpack image,
          "sh",
          "-c",
          T.unpack $
            "mkdir -p /volume/"
              <> workVolumeSubpath
              <> " && chown 0:0 /volume/"
              <> workVolumeSubpath
              <> " && chmod 700 /volume/"
              <> workVolumeSubpath
              <> " && find /volume -mindepth 1 -maxdepth 1 ! -name "
              <> workVolumeSubpath
              <> " -exec mv {} /volume/"
              <> workVolumeSubpath
              <> "/ \\; && chown -R 1000:1000 /volume/"
              <> workVolumeSubpath
        ]
        ""
  pure $ case result of
    Right (ExitSuccess, _, _) -> True
    _ -> False

-- | @docker rm -fv NAME@ — best-effort; ignores errors.
runRm :: Text -> IO ()
runRm name = do
  _ <-
    try @IOException $
      readProcessWithExitCode "docker" ["rm", "-fv", T.unpack name] ""
  pure ()

-- | @docker volume rm NAME@ — best-effort; ignores errors.
runVolumeRm :: Text -> IO ()
runVolumeRm name = do
  _ <-
    try @IOException $
      readProcessWithExitCode "docker" ["volume", "rm", T.unpack name] ""
  pure ()

-- | Names (not opaque container ids) in Max's owned namespace.
listContainersByPrefix :: Text -> IO [Text]
listContainersByPrefix prefix = do
  res <-
    try @IOException $
      readProcessWithExitCode
        "docker"
        ["ps", "-a", "--format", "{{.Names}}", "--filter", "name=^" <> T.unpack prefix]
        ""
  pure $ case res of
    Right (ExitSuccess, out, _) ->
      filter (not . T.null) (T.lines (T.pack out))
    _ -> []

inspectContainerStatus :: Text -> IO DockerContainerStatus
inspectContainerStatus name = do
  result <-
    try @IOException $
      readProcessWithExitCode
        "docker"
        ["container", "inspect", "--format", "{{.State.Running}}", T.unpack name]
        ""
  pure $ case result of
    Left err -> DockerContainerUnavailable (dockerIOException err)
    Right (ExitSuccess, out, _)
      | T.strip (T.pack out) == "true" -> DockerContainerRunning
      | otherwise -> DockerContainerStopped
    Right (ExitFailure code, out, err)
      | isMissingContainerError detail -> DockerContainerMissing
      | otherwise -> DockerContainerUnavailable (dockerFailure code detail)
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
        "docker"
        [ "container",
          "inspect",
          "--format",
          "{{index .Config.Labels \"max.sandbox.policy\"}}",
          T.unpack name
        ]
        ""
  pure $ case result of
    Right (ExitSuccess, out, _) -> T.strip (T.pack out) == sandboxPolicyVersion
    _ -> False

-- | @docker volume ls -q --filter "name=^PREFIX"@.
listVolumesByPrefix :: Text -> IO [Text]
listVolumesByPrefix prefix = do
  res <-
    try @IOException $
      readProcessWithExitCode
        "docker"
        ["volume", "ls", "-q", "--filter", "name=^" <> T.unpack prefix]
        ""
  pure $ case res of
    Right (ExitSuccess, out, _) ->
      filter (not . T.null) (T.lines (T.pack out))
    _ -> []

inspectVolumePresence :: Text -> IO DockerPresence
inspectVolumePresence name = do
  result <- try @IOException $ readProcessWithExitCode "docker" ["volume", "inspect", T.unpack name] ""
  pure $ case result of
    Left err -> DockerUnavailable (dockerIOException err)
    Right (ExitSuccess, _, _) -> DockerPresent
    Right (ExitFailure code, out, err)
      | isMissingVolumeError detail -> DockerAbsent
      | otherwise -> DockerUnavailable (dockerFailure code detail)
      where
        detail = T.strip (T.pack (out <> "\n" <> err))

isMissingContainerError :: Text -> Bool
isMissingContainerError detail =
  let lowered = T.toLower detail
   in "no such container" `T.isInfixOf` lowered
        || "no such object" `T.isInfixOf` lowered

isMissingVolumeError :: Text -> Bool
isMissingVolumeError detail =
  "no such volume" `T.isInfixOf` T.toLower detail

dockerIOException :: IOException -> Text
dockerIOException err = "docker inspection failed: " <> T.take 1000 (T.pack (show err))

dockerFailure :: Int -> Text -> Text
dockerFailure code detail =
  "docker inspection exited " <> T.pack (show code) <> ": " <> T.take 1000 detail

--------------------------------------------------------------------------------
-- Exec.

-- | Run @cmd@ inside @container@ with a hard wallclock cap, capturing
-- stdout/stderr.  Wraps the user command in @timeout SECONDS sh -c
-- '...'@ so the kill happens inside the container; we then just wait
-- for @docker exec@ to return.
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
  beforeDiff <- dockerDiff container
  _ <-
    try @IOException $
      readProcessWithExitCode
        "docker"
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
              (proc "docker" args)
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
                    ( dockerExecFailure
                        cmd
                        networkMode
                        (userError "docker exec did not expose all requested pipes")
                    )
        case processResult of
          Left e -> pure (dockerExecFailure cmd networkMode e)
          Right result -> pure result
  finished <- getPOSIXTime
  manifest <- observeManifest container marker beforeDiff
  pure
    base
      { erDurationMillis = max 0 (round ((finished - started) * 1000)),
        erObservedManifest = manifest
      }

-- | Realise allowlisted-by-construction nixpkgs attributes in a short-lived
-- helper.  This is the only sandbox-related process with bridge networking and
-- a writable shared Nix store.  The model controls only attribute arguments;
-- it cannot supply a shell command, image, mount, or network mode.  The actual
-- user command subsequently runs in the networkless non-root sandbox.
runPreparePackages :: Text -> [Text] -> Int -> IO (Either Text [Text])
runPreparePackages _ [] _ = pure (Right [])
runPreparePackages image packages timeoutSecs = do
  let expression = packageExpression packages
      args =
        [ "run",
          "--rm",
          "--network",
          "bridge",
          "--cap-drop",
          "ALL",
          "--security-opt",
          "no-new-privileges",
          "--memory",
          "4g",
          "--memory-swap",
          "4g",
          "--cpus",
          "2",
          "--pids-limit",
          "512",
          "-v",
          T.unpack nixVolume <> ":/nix",
          T.unpack image,
          "timeout",
          "--signal=TERM",
          "--kill-after=5s",
          T.unpack (T.pack (show timeoutSecs) <> "s"),
          "nix",
          "build",
          "--impure",
          "--no-link",
          "--print-out-paths",
          "--expr",
          T.unpack expression
        ]
  result <- try @IOException $ readProcessWithExitCode "docker" args ""
  pure $ case result of
    Left err -> Left ("package preparation failed: " <> T.pack (show err))
    Right (ExitSuccess, out, _) ->
      let paths = filter (not . T.null) (map T.strip (T.lines (T.pack out)))
       in if not (null paths) && all validPreparedStorePath paths
            then Right paths
            else Left "package preparation returned an invalid or empty store-path list"
    Right (ExitFailure code, out, err) ->
      Left $
        "package preparation exited "
          <> T.pack (show code)
          <> ": "
          <> T.takeEnd 4000 (stripAnsi (T.pack (out <> "\n" <> err)))

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

dockerExecFailure :: Text -> Text -> IOException -> ExecResult
dockerExecFailure cmd networkMode err =
  let detail = "docker exec failed: " <> T.pack (show err)
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
  dockerExecFailure cmd networkMode (userError (captureFailureMessage failures))
  where
    captureFailureMessage (outcome, errcome) =
      "stream capture failed: stdout=" <> render outcome <> "; stderr=" <> render errcome
    render = either show (const "ok")

-- | Hash and preview the observed /work manifest without streaming an
-- unbounded directory listing through the host process.  The temporary file
-- lives outside /work, so the observation does not change the state it names.
observeManifest :: Text -> Text -> [Text] -> IO (Maybe SandboxManifest)
observeManifest container marker beforeDiff = do
  let script =
        "tmp=$(mktemp /tmp/max-manifest.XXXXXX) || exit 1; "
          <> "find /work -xdev -type f -printf '%P\\t%s\\t%T@\\n' 2>/dev/null | LC_ALL=C sort >\"$tmp\"; "
          <> "sha256sum \"$tmp\" | cut -d' ' -f1; "
          <> "wc -l <\"$tmp\"; head -n 200 \"$tmp\"; rm -f \"$tmp\""
  result <-
    try @IOException $
      readProcessWithExitCode
        "docker"
        ["exec", "--workdir", "/work", T.unpack container, "sh", "-c", T.unpack script]
        ""
  changed <- observeChangedPaths container marker
  afterDiff <- dockerDiff container
  _ <-
    try @IOException $
      readProcessWithExitCode
        "docker"
        ["exec", T.unpack container, "sh", "-c", T.unpack ("rm -f " <> shellQuote marker)]
        ""
  let beforeSet = Set.fromList beforeDiff
      diffAll = filter (not . T.isInfixOf marker) (filter (`Set.notMember` beforeSet) afterDiff)
      (diffPreview, diffTruncated) = boundedLines 200 diffAll
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
                  smContainerDiff = diffPreview,
                  smContainerDiffTruncated = diffTruncated
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
        "docker"
        ["exec", "--workdir", "/work", T.unpack container, "sh", "-c", T.unpack script]
        ""
  pure $ case result of
    Right (ExitSuccess, out, _) -> boundedLines 200 (T.lines (T.pack out))
    _ -> ([], False)

dockerDiff :: Text -> IO [Text]
dockerDiff container = do
  result <- try @IOException $ readProcessWithExitCode "docker" ["diff", T.unpack container] ""
  pure $ case result of
    Right (ExitSuccess, out, _) -> filter (not . T.null) (T.lines (T.pack out))
    _ -> []

boundedLines :: Int -> [a] -> ([a], Bool)
boundedLines limit values = (take limit values, length values > limit)

digestText :: Text -> Text
digestText = TE.decodeUtf8 . Base16.encode . SHA256.hash . TE.encodeUtf8

textBytes :: Text -> Int
textBytes = BS.length . TE.encodeUtf8

-- | Copy the bounded host-side captures back into the sandbox and assemble a
-- readable combined spill.  @docker cp@ streams from disk, so this does not
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
            "docker"
            ["cp", host, T.unpack container <> ":" <> T.unpack target]
            ""
  created <- dockerExecSmall container "mkdir -p /work/.max-out"
  copiedOut <- if created then copy stdoutPath stagedOut else pure (Left (userError "spill directory unavailable"))
  copiedErr <- case copiedOut of
    Right (ExitSuccess, _, _) -> copy stderrPath stagedErr
    _ -> pure (Left (userError "stdout spill copy failed"))
  assembled <- case copiedErr of
    Right (ExitSuccess, _, _) ->
      dockerExecSmall container (assembleSpill path stagedOut stagedErr capturedOut capturedErr)
    _ -> pure False
  if assembled
    then pure (Just path)
    else do
      _ <- dockerExecSmall container ("rm -f " <> shellQuote stagedOut <> " " <> shellQuote stagedErr <> " " <> shellQuote path)
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

dockerExecSmall :: Text -> Text -> IO Bool
dockerExecSmall container command = do
  result <-
    try @IOException $
      readProcessWithExitCode
        "docker"
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
  res <- try @IOException $ readProcessWithExitCode "docker" args ""
  pure $ case res of
    Left e -> Left ("docker exec failed: " <> T.pack (show e))
    Right (ExitSuccess, out, _) -> Right (T.pack out)
    Right (ExitFailure c, _, err) ->
      Left $
        "read failed (exit "
          <> T.pack (show c)
          <> "): "
          <> T.strip (T.pack err)

-- | Write @content@ to a file inside the container, overwriting if
-- present.  Uses @docker exec -i ... tee@ with content fed via stdin
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
      proc' = (proc "docker" args) {std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
  res <- try @IOException $ readCreateProcessWithExitCode proc' (T.unpack content)
  pure $ case res of
    Left e -> Left ("docker exec failed: " <> T.pack (show e))
    Right (ExitSuccess, _, _) -> Right ()
    Right (ExitFailure c, _, err) ->
      Left $
        "write failed (exit "
          <> T.pack (show c)
          <> "): "
          <> T.strip (T.pack err)

--------------------------------------------------------------------------------
-- Copy in/out.

-- | @docker cp HOST_PATH CONTAINER:CONTAINER_PATH@.  Used by
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
        "docker"
        [ "cp",
          hostPath,
          T.unpack container <> ":" <> T.unpack containerPath
        ]
        ""
  pure $ case res of
    Left e -> Left ("docker cp failed: " <> T.pack (show e))
    Right (ExitSuccess, _, _) -> Right ()
    Right (ExitFailure c, _, err) ->
      Left $
        "docker cp exited "
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
          "docker"
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

-- | @docker cp CONTAINER:CONTAINER_PATH HOST_PATH@.  Used by
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
        "docker"
        [ "cp",
          T.unpack container <> ":" <> T.unpack containerPath,
          hostPath
        ]
        ""
  pure $ case res of
    Left e -> Left ("docker cp failed: " <> T.pack (show e))
    Right (ExitSuccess, _, _) -> Right ()
    Right (ExitFailure c, _, err) ->
      Left $
        "docker cp exited "
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
-- fixed helper with narrowly scoped network authority.  The networkless,
-- non-root sandbox therefore never needs write access to the shared Nix DB.
-- A bare @python3Packages.*@ derivation does not alter Python's import path, so
-- 'packageExpression' collects those attributes into one
-- @python3.withPackages@ environment.  Every attribute segment is quoted and
-- validated by the registry before this expression is built.
wrapPackages :: [Text] -> Text -> Text
wrapPackages [] cmd = cmd
wrapPackages storePaths cmd =
  "export PATH="
    <> shellQuote (T.intercalate ":" (map (<> "/bin") storePaths))
    <> ":\"$PATH\"; exec sh -c "
    <> shellQuote cmd

packageExpression :: [Text] -> Text
packageExpression packages =
  "let pkgs = (builtins.getFlake \"nixpkgs\").legacyPackages.${builtins.currentSystem}; in [ "
    <> T.unwords (map (attributeValue "pkgs") ordinary <> pythonEnvironment)
    <> " ]"
  where
    (python, ordinary) = foldr classify ([], []) packages
    classify attr (pythonAttrs, ordinaryAttrs) = case T.stripPrefix "python3Packages." attr of
      Just suffix -> (suffix : pythonAttrs, ordinaryAttrs)
      Nothing -> (pythonAttrs, attr : ordinaryAttrs)
    pythonEnvironment =
      [ "(pkgs.python3.withPackages (ps: [ "
          <> T.unwords (map (attributeValue "ps") python)
          <> " ]))"
      | not (null python)
      ]

attributeValue :: Text -> Text -> Text
attributeValue root =
  foldl
    (\parent segment -> "(builtins.getAttr \"" <> segment <> "\" " <> parent <> ")")
    root
    . T.splitOn "."
