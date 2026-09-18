-- | Group-scoped sandbox lifecycle, commands, files and Nix package lookup.
-- The host broker resolves requested packages into the guest's PATH. Sandboxes
-- persist across turns and are shared within a group: independent commands may
-- run concurrently, lifecycle changes wait, and callers coordinate paths/ports.
module Max.Tools.Sandbox
  ( sandboxToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Maybe (fromMaybe)
import Data.Ord (clamp)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone)
import Effectful
import Max.Effects.Sandbox
  ( Sandbox,
    createSandbox,
    destroySandbox,
    execInSandbox,
    listSandboxes,
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
    SandboxId (SandboxId, unSandboxId),
    SandboxInfo (seContainer, seCreatedAt, seId, seImage),
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
    maxOutputBytes,
  )
import Max.Time (fmtDateHMS)
import Max.Tools.Schema
  ( integerParam,
    noArguments,
    stringArrayParam,
    stringParam,
    toolObject,
    withKeys,
  )

sandboxToolsFor :: (Sandbox :> es) => TimeZone -> [Tool es]
sandboxToolsFor tz =
  [ createTool,
    execTool,
    nixSearchTool,
    listTool tz,
    destroyTool,
    readFileTool,
    writeFileTool
  ]

--------------------------------------------------------------------------------
-- sandbox_create

createTool :: (Sandbox :> es) => Tool es
createTool =
  Tool
    { toolName = "sandbox_create",
      toolDescription =
        T.unwords
          [ "Create a Linux sandbox (NixOS container) and get the 'sandbox_id' the",
            "other sandbox_* tools take.  Nix-based: do NOT apt/yum install — pass",
            "nixpkgs attributes in sandbox_exec's 'packages' instead.  Sandboxes",
            "persist across dispatches and are shared with this group's other",
            "running tasks: prefer reusing one from sandbox_list.",
            "开工前先 use_skill 取 sandbox 手册。"
          ],
      toolSchema = noArguments,
      toolRunner = LegacyRunner $ \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right () -> do
            res <- createSandbox
            pure $ case res of
              Left err -> Left err
              Right e ->
                Right $
                  object
                    [ "sandbox_id" .= e.seId.unSandboxId,
                      "image" .= e.seImage,
                      "container" .= e.seContainer,
                      "note" .= ("Use sandbox_exec with sandbox_id to run commands." :: Text)
                    ]
    }
  where
    parseArgs :: Object -> Parser ()
    parseArgs _ = pure ()

--------------------------------------------------------------------------------
-- sandbox_exec

execTool :: (Sandbox :> es) => Tool es
execTool =
  Tool
    { toolName = "sandbox_exec",
      toolDescription =
        T.unwords
          [ "Run a shell command in a sandbox (verbatim 'sh -c', wallclock",
            "timeout, exit_code 0 = success). Independent commands may run concurrently in the same sandbox; coordinate shared paths and ports. Output capped ~16 KiB per",
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
          [ ("sandbox_id", stringParam "Sandbox id from sandbox_create."),
            ("command", stringParam "Shell command to run."),
            ( "packages",
              withKeys ["maxItems" .= (32 :: Int)] $
                stringArrayParam "nixpkgs attributes to put on PATH for this command (find them with nix_search); python3Packages.* attributes are also made importable."
            ),
            ( "timeout_seconds",
              withKeys ["default" .= (30 :: Int)] (integerParam "Max wallclock seconds (default 30, max 600).")
            )
          ]
          ["sandbox_id", "command"],
      toolRunner = LegacyRunner $ \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (sid, cmd, pkgs, t) -> do
            res <- execInSandbox (SandboxId sid) pkgs cmd (clamp (1, 600) t)
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
    parseArgs :: Object -> Parser (Text, Text, [Text], Int)
    parseArgs o = do
      sid <- o .: "sandbox_id"
      cmd <- o .: "command"
      pkgs <- o .:? "packages" .!= []
      mTo <- o .:? "timeout_seconds"
      pure (sid, cmd, pkgs, fromMaybe 30 mTo)

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

-- | Search the host-owned package pin after checking sandbox ownership.
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
          [ ("sandbox_id", stringParam "Sandbox id to search in."),
            ("query", stringParam "Regex matched against package names and descriptions.")
          ]
          ["sandbox_id", "query"],
      toolRunner = LegacyRunner $ \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (sid, query) -> do
            res <- searchPackages (SandboxId sid) query
            pure $ case res of
              Left err -> Left err
              Right results
                | T.null (T.strip results) ->
                    Right (object ["results" .= ("" :: Text), "note" .= ("no packages matched; try a broader regex" :: Text)])
                | otherwise ->
                    Right (object ["results" .= T.take maxOutputBytes results, "truncated" .= (T.length results > maxOutputBytes)])
    }
  where
    parseArgs :: Object -> Parser (Text, Text)
    parseArgs o = (,) <$> o .: "sandbox_id" <*> o .: "query"

--------------------------------------------------------------------------------
-- sandbox_list

listTool :: (Sandbox :> es) => TimeZone -> Tool es
listTool tz =
  Tool
    { toolName = "sandbox_list",
      toolDescription =
        "List sandboxes available in this group's session (created by you or by other parallel dispatches).",
      toolSchema = noArguments,
      toolRunner = LegacyRunner $ \_args -> Right . toJSON . map summarize <$> listSandboxes
    }
  where
    summarize e =
      object
        [ "sandbox_id" .= e.seId.unSandboxId,
          "image" .= e.seImage,
          "created_at" .= fmtDateHMS tz e.seCreatedAt
        ]

--------------------------------------------------------------------------------
-- sandbox_destroy

destroyTool :: (Sandbox :> es) => Tool es
destroyTool =
  Tool
    { toolName = "sandbox_destroy",
      toolDescription =
        "Permanently destroy a sandbox and its /work data (downloaded packages \
        \survive in the shared store).  Use when done, to free resources.",
      toolSchema = toolObject [("sandbox_id", stringParam "Sandbox id to destroy.")] ["sandbox_id"],
      toolRunner = LegacyRunner $ \args ->
        case parseEither (withObject "args" (\o -> o .: "sandbox_id")) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (sid :: Text) -> do
            res <- destroySandbox (SandboxId sid)
            pure $ case res of
              Left err -> Left err
              Right () -> Right (object ["ok" .= True])
    }

--------------------------------------------------------------------------------
-- sandbox_read_file

readFileTool :: (Sandbox :> es) => Tool es
readFileTool =
  Tool
    { toolName = "sandbox_read_file",
      toolDescription =
        "Read up to max_bytes of a text file in a sandbox (path relative to \
        \/work, or absolute; UTF-8, silently truncated at the cap).",
      toolSchema =
        toolObject
          [ ("sandbox_id", stringParam "Sandbox id."),
            ("path", stringParam "File path (relative to /work, or absolute)."),
            ( "max_bytes",
              withKeys ["default" .= (maxOutputBytes :: Int)] (integerParam "Cap (default 16384, max 65536).")
            )
          ]
          ["sandbox_id", "path"],
      toolRunner = LegacyRunner $ \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (sid, path, mx) -> do
            res <- readSandboxFile (SandboxId sid) path (clamp (1, 65536) mx)
            pure $ case res of
              Left err -> Left err
              Right content ->
                Right $
                  object
                    [ "content" .= content,
                      "bytes" .= T.length content
                    ]
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Int)
    parseArgs o = do
      sid <- o .: "sandbox_id"
      path <- o .: "path"
      mx <- o .:? "max_bytes"
      pure (sid, path, fromMaybe maxOutputBytes mx)

--------------------------------------------------------------------------------
-- sandbox_write_file

writeFileTool :: (Sandbox :> es) => Tool es
writeFileTool =
  Tool
    { toolName = "sandbox_write_file",
      toolDescription =
        "Write a text file in a sandbox (creates parent dirs, overwrites) — \
        \e.g. drop a script before sandbox_exec runs it.",
      toolSchema =
        toolObject
          [ ("sandbox_id", stringParam "Sandbox id."),
            ("path", stringParam "File path (relative to /work, or absolute)."),
            ("content", stringParam "File content (UTF-8 text).")
          ]
          ["sandbox_id", "path", "content"],
      toolRunner = LegacyRunner $ \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (sid, path, content) -> do
            res <- writeSandboxFile (SandboxId sid) path content
            pure $ case res of
              Left err -> Left err
              Right () -> Right (object ["ok" .= True, "bytes" .= T.length content])
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Text)
    parseArgs o = (,,) <$> o .: "sandbox_id" <*> o .: "path" <*> o .: "content"

--------------------------------------------------------------------------------
-- Helpers.
