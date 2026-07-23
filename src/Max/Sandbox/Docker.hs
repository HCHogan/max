-- |
-- Thin @docker@ CLI wrappers via 'System.Process'.  We shell out
-- rather than talk the HTTP API because (a) the CLI is already
-- installed wherever 'docker run' works, (b) error messages are
-- familiar to humans reading logs, and (c) it's ~200 lines less
-- code.
--
-- == Output limits
--
-- 'runExec' caps captured @stdout@/@stderr@ at 'maxOutputBytes'
-- each.  Past that, 'erTruncated' is set and the FULL output is
-- spilled to a file inside the container ('erSpillPath', under
-- @/work/.max-out/@) so the model can grep/head the rest with its
-- own exec tool instead of losing it.  Per-call wallclock deadline
-- is enforced *inside the container* via @timeout(1)@ so runaway
-- processes are killed where they live rather than leaving us a
-- dangling 'docker exec' to wrestle with.
module Max.Sandbox.Docker
  ( -- * Lifecycle
    runRun,
    runRm,
    runVolumeRm,
    listContainersByPrefix,
    listVolumesByPrefix,
    -- * Exec
    ExecResult (..),
    runExec,
    runRead,
    runWrite,
    -- * Copy
    runCopyToContainer,
    runCopyFromContainer,
    -- * Tuning knobs
    maxOutputBytes,
    nixVolume,
    -- * Helpers
    shellQuote,
    wrapPackages,
    stripAnsi,
  )
where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import System.Exit (ExitCode (..))
import System.Process
  ( CreateProcess (..),
    StdStream (..),
    proc,
    readCreateProcessWithExitCode,
    readProcessWithExitCode,
  )

-- | Per-call stdout/stderr cap (bytes).  Anything past this is
-- dropped; the caller sees a 'truncated' flag.
maxOutputBytes :: Int
maxOutputBytes = 16 * 1024

-- | Shared nix store volume, mounted at /nix in every sandbox so a
-- package downloaded once is instant for all later sandboxes.  On
-- the first ever run docker seeds it from the image's /nix.
-- Deliberately outside the @max-sb-@ namespace so the startup reaper
-- never touches it; it survives bot restarts by design.
nixVolume :: Text
nixVolume = "max-nix"

-- | Result of one in-container exec.
data ExecResult = ExecResult
  { erExitCode :: !Int,
    erStdout :: !Text,
    erStderr :: !Text,
    erTruncated :: !Bool,
    -- | When truncated: container-side path holding the full
    -- stdout+stderr, for the model to grep/head on demand.
    erSpillPath :: !(Maybe Text)
  }
  deriving stock (Show)

--------------------------------------------------------------------------------
-- Lifecycle.

-- | @docker run -d --init --name NAME [...args] IMAGE sleep infinity@.
-- Mounts the per-sandbox work volume at /work and the shared
-- 'nixVolume' at /nix.  No memory/cpu caps: nixpkgs evaluation alone
-- can want ~2 GiB, and sandboxes are per-group already.
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
  let args =
        [ "run",
          "-d",
          "--init",
          "--name",
          T.unpack name,
          "--network",
          T.unpack network,
          "-v",
          T.unpack nixVolume <> ":/nix",
          "-v",
          T.unpack volume <> ":/work",
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

-- | @docker ps -aq --filter "name=^PREFIX"@.
listContainersByPrefix :: Text -> IO [Text]
listContainersByPrefix prefix = do
  res <-
    try @IOException $
      readProcessWithExitCode
        "docker"
        ["ps", "-aq", "--filter", "name=^" <> T.unpack prefix]
        ""
  pure $ case res of
    Right (ExitSuccess, out, _) ->
      filter (not . T.null) (T.lines (T.pack out))
    _ -> []

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

--------------------------------------------------------------------------------
-- Exec.

-- | Run @cmd@ inside @container@ with a hard wallclock cap, capturing
-- stdout/stderr.  Wraps the user command in @timeout SECONDS sh -c
-- '...'@ so the kill happens inside the container; we then just wait
-- for @docker exec@ to return.
runExec ::
  -- | container name
  Text ->
  -- | shell command (passed to @sh -c@)
  Text ->
  -- | timeout seconds
  Int ->
  IO ExecResult
runExec container cmd timeoutSecs = do
  let wrapped =
        "timeout --preserve-status "
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
  res <- try @IOException $ readProcessWithExitCode "docker" args ""
  case res of
    Left e ->
      pure
        ExecResult
          { erExitCode = -1,
            erStdout = "",
            erStderr = "docker exec failed: " <> T.pack (show e),
            erTruncated = False,
            erSpillPath = Nothing
          }
    Right (code, out, err) -> do
      let fullOut = stripAnsi (T.pack out)
          fullErr = stripAnsi (T.pack err)
          (truncatedOut, t1) = truncateBytes maxOutputBytes fullOut
          (truncatedErr, t2) = truncateBytes maxOutputBytes fullErr
      spill <-
        if t1 || t2
          then spillOutput container fullOut fullErr
          else pure Nothing
      pure
        ExecResult
          { erExitCode = case code of ExitSuccess -> 0; ExitFailure c -> c,
            erStdout = truncatedOut,
            erStderr = truncatedErr,
            erTruncated = t1 || t2,
            erSpillPath = spill
          }

-- | Save an over-cap exec's full output to a file inside the
-- container, so truncation stops being lossy.  Best-effort: any
-- failure just means no spill path (old behavior).
spillOutput :: Text -> Text -> Text -> IO (Maybe Text)
spillOutput container fullOut fullErr = do
  stamp <- (show :: Int -> String) . round . (* 1000) <$> getPOSIXTime
  let path = "/work/.max-out/exec-" <> T.pack stamp <> ".log"
      content = "### stdout\n" <> fullOut <> "\n### stderr\n" <> fullErr
      args =
        [ "exec",
          "-i",
          T.unpack container,
          "sh",
          "-c",
          T.unpack ("mkdir -p /work/.max-out && cat > " <> shellQuote path)
        ]
  res <- try @IOException $ readProcessWithExitCode "docker" args (T.unpack content)
  pure $ case res of
    Right (ExitSuccess, _, _) -> Just path
    _ -> Nothing

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

-- | Put @pkgs@ (bare nixpkgs attribute names) on PATH for one command
-- via @nix shell@, which realises them from the shared store and
-- execs the command with them available — nothing is installed into
-- the sandbox itself.  Empty list = run the command as-is.
--
-- Two passes: a silenced warm-up run realises the packages (this is
-- where nix's "these paths will be fetched … / copying path …"
-- chatter goes — straight to @/dev/null@), then the real run executes
-- in the now-cached shell so its captured stderr carries only the
-- command's own output, not nix's.
wrapPackages :: [Text] -> Text -> Text
wrapPackages [] cmd = cmd
wrapPackages pkgs cmd =
  nixShell <> " -c true >/dev/null 2>&1; "
    <> nixShell <> " -c sh -c " <> shellQuote cmd
  where
    nixShell = "nix shell " <> T.unwords [shellQuote ("nixpkgs#" <> p) | p <- pkgs]

-- | Cap a Text at @n@ bytes (approximate — uses character count;
-- close enough for log/model display).  Returns the trimmed text and
-- a flag that's true iff anything was dropped.
truncateBytes :: Int -> Text -> (Text, Bool)
truncateBytes n t
  | T.length t <= n = (t, False)
  | otherwise = (T.take n t <> "\n…(truncated)", True)
