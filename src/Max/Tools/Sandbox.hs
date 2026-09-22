-- | The group's sandbox: commands, files and Nix package lookup. The host
-- starts the sandbox on first use and keeps it across turns; it is shared
-- within a group, so independent commands may run concurrently, lifecycle
-- changes wait, and callers coordinate paths/ports. /work is the persistent
-- workspace and /chat a read-only mirror of this chat's files.
module Max.Tools.Sandbox
  ( sandboxTools,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Ord (clamp)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Max.Effects.Sandbox
  ( Sandbox,
    destroySandbox,
    execInSandbox,
    readSandboxFile,
    searchPackages,
    writeSandboxFile,
  )
import Max.Effects.Tools (Tool (..), ToolRunner (..))
import Max.Sandbox.Types
  ( ExecResult
      ( erActualCommand,
        erDurationMillis,
        erExitCode,
        erNetworkMode,
        erObservedManifest,
        erSpillPath,
        erSpillTruncated,
        erStderr,
        erStderrBytes,
        erStderrSha256,
        erStdout,
        erStdoutBytes,
        erStdoutSha256,
        erTruncated
      ),
    SandboxManifest
      ( smChangedPaths,
        smChangedPathsTruncated,
        smContainerDiff,
        smContainerDiffTruncated,
        smFileCount,
        smPreview,
        smSha256,
        smTruncated
      ),
    SandboxRead (srBytes, srContent, srTruncated),
    maxOutputBytes,
  )
import Max.Tools.Schema
  ( integerParam,
    noArguments,
    stringArrayParam,
    stringParam,
    toolObject,
    withKeys,
  )

sandboxTools :: (Sandbox :> es) => [Tool es]
sandboxTools =
  [ execTool,
    nixSearchTool,
    destroyTool,
    readFileTool,
    writeFileTool
  ]

--------------------------------------------------------------------------------
-- sandbox_exec

execTool :: (Sandbox :> es) => Tool es
execTool =
  Tool
    { toolName = "sandbox_exec",
      toolDescription =
        T.unwords
          [ "Run a shell command in this group's sandbox (verbatim 'sh -c' in /work, wallclock",
            "timeout, exit_code 0 = success). /work persists; /chat is a read-only mirror of this chat's files and media.",
            "Independent commands may run concurrently; coordinate shared paths and ports. Output capped ~16 KiB per",
            "stream; when 'truncated' is true a bounded output spill is saved",
            "to 'full_output_file'.  'spill_truncated' says whether that file",
            "also reached its safety cap — inspect it instead of re-running.",
            "Public internet access is available. Operations-enabled groups also have Tailscale access; otherwise host, private-network and peer-sandbox",
            "connections are blocked. External writes still need task authorization.",
            "Tools not preinstalled: list nixpkgs attributes in 'packages'",
            "(first use downloads — raise timeout_seconds to 120-300)."
          ],
      toolSchema =
        toolObject
          [ ("command", stringParam "Shell command to run."),
            ( "packages",
              withKeys ["maxItems" .= (32 :: Int)] $
                stringArrayParam "nixpkgs attributes to put on PATH for this command (find them with nix_search); python3Packages.* attributes are also made importable."
            ),
            ( "timeout_seconds",
              withKeys ["default" .= (30 :: Int)] (integerParam "Max wallclock seconds (default 30, max 600).")
            )
          ]
          ["command"],
      toolRunner = LegacyRunner $ \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (cmd, pkgs, t) -> do
            res <- execInSandbox pkgs cmd (clamp (1, 600) t)
            pure $ case res of
              Left err -> Left err
              Right er ->
                Right . object $
                  [ "exit_code" .= er.erExitCode,
                    "stdout" .= er.erStdout,
                    "stderr" .= er.erStderr,
                    "truncated" .= er.erTruncated,
                    "spill_truncated" .= er.erSpillTruncated
                  ]
                    <> ["full_output_file" .= p | Just p <- [er.erSpillPath]]
                    <> ["_max_journal_observed_manifest" .= journalObservation er]
    }
  where
    parseArgs :: Object -> Parser (Text, [Text], Int)
    parseArgs o = do
      cmd <- o .: "command"
      pkgs <- o .:? "packages" .!= []
      mTo <- o .:? "timeout_seconds"
      pure (cmd, pkgs, fromMaybe 30 mTo)

journalObservation :: ExecResult -> Value
journalObservation er =
  object
    [ "command" .= er.erActualCommand,
      "exit_code" .= er.erExitCode,
      "duration_ms" .= er.erDurationMillis,
      "network_mode" .= er.erNetworkMode,
      "stdout"
        .= object
          [ "sha256" .= er.erStdoutSha256,
            "bytes" .= er.erStdoutBytes,
            "spill_path" .= er.erSpillPath,
            "spill_truncated" .= er.erSpillTruncated
          ],
      "stderr"
        .= object
          [ "sha256" .= er.erStderrSha256,
            "bytes" .= er.erStderrBytes
          ],
      "filesystem" .= fmap filesystemObservation er.erObservedManifest
    ]
  where
    filesystemObservation manifest =
      object
        [ "manifest_sha256" .= manifest.smSha256,
          "file_count" .= manifest.smFileCount,
          "manifest_preview" .= manifest.smPreview,
          "manifest_truncated" .= manifest.smTruncated,
          "changed_paths" .= manifest.smChangedPaths,
          "changed_paths_truncated" .= manifest.smChangedPathsTruncated,
          "container_diff" .= manifest.smContainerDiff,
          "container_diff_truncated" .= manifest.smContainerDiffTruncated
        ]

--------------------------------------------------------------------------------
-- nix_search

-- | Search the host-owned package pin.
nixSearchTool :: (Sandbox :> es) => Tool es
nixSearchTool =
  Tool
    { toolName = "nix_search",
      toolDescription =
        T.unwords
          [ "Search the sandbox's pinned nixpkgs by regex (e.g. 'ffmpeg',",
            "'python.*opencv').  Returns 'attribute version description' lines;",
            "pass the attribute in sandbox_exec's 'packages'.  Empty result:",
            "broaden the regex."
          ],
      toolSchema =
        toolObject
          [("query", stringParam "Regex matched against package names and descriptions.")]
          ["query"],
      toolRunner = LegacyRunner $ \args ->
        case parseEither (withObject "args" (.: "query")) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right query -> do
            res <- searchPackages query
            pure $ case res of
              Left err -> Left err
              Right results
                | T.null (T.strip results) ->
                    Right (object ["results" .= ("" :: Text), "note" .= ("no packages matched; try a broader regex" :: Text)])
                | otherwise ->
                    Right (object ["results" .= T.take maxOutputBytes results, "truncated" .= (T.length results > maxOutputBytes)])
    }

--------------------------------------------------------------------------------
-- sandbox_destroy

destroyTool :: (Sandbox :> es) => Tool es
destroyTool =
  Tool
    { toolName = "sandbox_destroy",
      toolDescription =
        "Delete this group's sandbox and everything in /work (downloaded \
        \packages survive in the shared store).  The next sandbox call starts \
        \a fresh one.  Other tasks in the group share it.",
      toolSchema = noArguments,
      toolRunner = LegacyRunner $ \_args -> do
        destroyed <- destroySandbox
        pure (Right (object ["ok" .= True, "destroyed" .= destroyed]))
    }

--------------------------------------------------------------------------------
-- read_file

readFileTool :: (Sandbox :> es) => Tool es
readFileTool =
  Tool
    { toolName = "read_file",
      toolDescription =
        "Read the start of a text file in the sandbox (absolute path, or \
        \relative to /work; /chat holds this chat's files).  Returns up to \
        \max_bytes of UTF-8; for a binary file only its size — process it \
        \with sandbox_exec instead.",
      toolSchema =
        toolObject
          [ ("path", stringParam "File path (absolute, or relative to /work)."),
            ( "max_bytes",
              withKeys ["default" .= (maxOutputBytes :: Int)] (integerParam "Cap (default 16384, max 65536).")
            )
          ]
          ["path"],
      toolRunner = LegacyRunner $ \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (path, mx) -> do
            res <- readSandboxFile path (clamp (1, 65536) mx)
            pure $ case res of
              Left err -> Left err
              Right read' -> Right . object $ case read'.srContent of
                Just content -> ["content" .= content, "bytes" .= read'.srBytes, "truncated" .= read'.srTruncated]
                Nothing -> ["binary" .= True, "bytes_read" .= read'.srBytes, "truncated" .= read'.srTruncated]
    }
  where
    parseArgs :: Object -> Parser (Text, Int)
    parseArgs o = do
      path <- o .: "path"
      mx <- o .:? "max_bytes"
      pure (path, fromMaybe maxOutputBytes mx)

--------------------------------------------------------------------------------
-- write_file

writeFileTool :: (Sandbox :> es) => Tool es
writeFileTool =
  Tool
    { toolName = "write_file",
      toolDescription =
        "Write a UTF-8 text file in the sandbox (absolute path, or relative \
        \to /work; creates parent directories, overwrites).  /chat is read-only.",
      toolSchema =
        toolObject
          [ ("path", stringParam "File path (absolute, or relative to /work)."),
            ("content", stringParam "File content (UTF-8 text).")
          ]
          ["path", "content"],
      toolRunner = LegacyRunner $ \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (path, content) -> do
            res <- writeSandboxFile path content
            pure $ case res of
              Left err -> Left err
              Right () -> Right (object ["ok" .= True, "bytes" .= BS.length (TE.encodeUtf8 content)])
    }
  where
    parseArgs :: Object -> Parser (Text, Text)
    parseArgs o = (,) <$> o .: "path" <*> o .: "content"
