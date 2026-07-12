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
-- each.  Past that, the rest is dropped silently and 'erTruncated'
-- is set so the tool can tell the model.  Per-call wallclock
-- deadline is enforced *inside the container* via @timeout(1)@ so
-- runaway processes are killed where they live rather than leaving
-- us a dangling 'docker exec' to wrestle with.
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
  )
where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as T
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
    erTruncated :: !Bool
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
  pure $ case res of
    Left e ->
      ExecResult
        { erExitCode = -1,
          erStdout = "",
          erStderr = "docker exec failed: " <> T.pack (show e),
          erTruncated = False
        }
    Right (code, out, err) ->
      let (truncatedOut, t1) = truncateBytes maxOutputBytes (T.pack out)
          (truncatedErr, t2) = truncateBytes maxOutputBytes (T.pack err)
       in ExecResult
            { erExitCode = case code of ExitSuccess -> 0; ExitFailure c -> c,
              erStdout = truncatedOut,
              erStderr = truncatedErr,
              erTruncated = t1 || t2
            }

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

-- | Cap a Text at @n@ bytes (approximate — uses character count;
-- close enough for log/model display).  Returns the trimmed text and
-- a flag that's true iff anything was dropped.
truncateBytes :: Int -> Text -> (Text, Bool)
truncateBytes n t
  | T.length t <= n = (t, False)
  | otherwise = (T.take n t <> "\n…(truncated)", True)
