-- |
-- Sandbox tools exposed to the agent: create / exec / list /
-- destroy / read_file / write_file / nix_search.  All scoped to the
-- calling group's session.
--
-- == What the model sees
--
-- A small JSON-schema'd toolkit for "run stuff in a Linux box".
-- The box is nix-based (image built from @sandbox-image/@, nixpkgs
-- pinned to 26.05, /nix shared across all sandboxes): instead of
-- apt-installing, the model passes @packages@ to @sandbox_exec@ and
-- we wrap the command in @nix shell nixpkgs#… -c@, so models that
-- don't know nix never have to write a nix command; @nix_search@
-- covers discovery.  The sandbox survives across @-mention
-- dispatches; the model is told this so it can reuse one between
-- turns instead of recreating.
--
-- == Concurrency disclosure
--
-- The tool descriptions warn the model that sandboxes are shared
-- within the group's session — multiple parallel dispatches can
-- target the same sandbox.  Per-sandbox 'execInSandbox' serialization
-- protects against concurrent shell invocations corrupting each
-- other; same-file writes are still a coordination problem the
-- model must reason about.
module Max.Tools.Sandbox
  ( sandboxToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone)
import Effectful
import Max.Effects.Tools (Tool (..))
import Max.Sandbox.Docker (ExecResult (..), maxOutputBytes, shellQuote, wrapPackages)
import Max.Sandbox.Registry
  ( SandboxCreateOpts (..),
    SandboxEntry (..),
    SandboxId (..),
    SandboxRegistry,
    createSandbox,
    defaultCreateOpts,
    destroySandbox,
    execInSandbox,
    listSandboxesForGroup,
    readSandboxFile,
    writeSandboxFile,
  )
import Max.Time (fmtDateHMS)
import OneBot.Types (GroupId)

sandboxToolsFor :: IOE :> es => TimeZone -> GroupId -> SandboxRegistry -> [Tool es]
sandboxToolsFor tz gid reg =
  [ createTool gid reg,
    execTool gid reg,
    nixSearchTool gid reg,
    listTool tz gid reg,
    destroyTool gid reg,
    readFileTool gid reg,
    writeFileTool gid reg
  ]

--------------------------------------------------------------------------------
-- sandbox_create

createTool :: IOE :> es => GroupId -> SandboxRegistry -> Tool es
createTool gid reg =
  Tool
    { toolName = "sandbox_create",
      toolDescription =
        T.unwords
          [ "Create a Linux sandbox (Docker container) and get the 'sandbox_id' the",
            "other sandbox_* tools take.  Nix-based: do NOT apt/yum install — pass",
            "nixpkgs attributes in sandbox_exec's 'packages' instead.  Sandboxes",
            "persist across dispatches and are shared with this group's other",
            "running tasks: prefer reusing one from sandbox_list.",
            "开工前先 use_skill 取 sandbox 手册。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "image"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("Docker image (default max-sandbox:latest, the nix-enabled base; only override if you have a specific reason)." :: Text)
                      ],
                  "network"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("bridge | none (default bridge)." :: Text),
                        "enum" .= (["bridge", "none"] :: [Text])
                      ]
                ],
            "required" .= ([] :: [Text])
          ],
      toolRun = \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right opts -> do
            res <- liftIO (createSandbox reg gid opts)
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
    parseArgs :: Object -> Parser SandboxCreateOpts
    parseArgs o = do
      mImg <- o .:? "image"
      mNet <- o .:? "network"
      pure
        defaultCreateOpts
          { scoImage = maybe (scoImage defaultCreateOpts) id mImg,
            scoNetwork = maybe (scoNetwork defaultCreateOpts) id mNet
          }

--------------------------------------------------------------------------------
-- sandbox_exec

execTool :: IOE :> es => GroupId -> SandboxRegistry -> Tool es
execTool gid reg =
  Tool
    { toolName = "sandbox_exec",
      toolDescription =
        T.unwords
          [ "Run a shell command in a sandbox (verbatim 'sh -c', wallclock",
            "timeout, exit_code 0 = success).  Output capped ~16 KiB per",
            "stream; when 'truncated' is true the full output is saved to",
            "'full_output_file' — grep/tail that file next, don't re-run.",
            "Tools not preinstalled: list nixpkgs attributes in 'packages'",
            "(first use downloads — raise timeout_seconds to 120-300)."
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "sandbox_id" .= stringField "Sandbox id from sandbox_create.",
                  "command" .= stringField "Shell command to run.",
                  "packages"
                    .= object
                      [ "type" .= ("array" :: Text),
                        "items" .= object ["type" .= ("string" :: Text)],
                        "description"
                          .= ("nixpkgs attributes to put on PATH for this command (find them with nix_search)." :: Text)
                      ],
                  "timeout_seconds"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("Max wallclock seconds (default 30, max 600)." :: Text),
                        "default" .= (30 :: Int)
                      ]
                ],
            "required" .= (["sandbox_id", "command"] :: [Text])
          ],
      toolRun = \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (sid, cmd, pkgs, t) -> do
            res <- liftIO (execInSandbox reg gid (SandboxId sid) (wrapPackages pkgs cmd) (clampTimeout t))
            pure $ case res of
              Left err -> Left err
              Right er ->
                Right . object $
                  [ "exit_code" .= er.erExitCode,
                    "stdout" .= er.erStdout,
                    "stderr" .= er.erStderr,
                    "truncated" .= er.erTruncated
                  ]
                    <> ["full_output_file" .= p | Just p <- [er.erSpillPath]]
    }
  where
    parseArgs :: Object -> Parser (Text, Text, [Text], Int)
    parseArgs o = do
      sid <- o .: "sandbox_id"
      cmd <- o .: "command"
      pkgs <- o .:? "packages" .!= []
      mTo <- o .:? "timeout_seconds"
      pure (sid, cmd, pkgs, maybe 30 id mTo)

    clampTimeout n = max 1 (min 600 n)

--------------------------------------------------------------------------------
-- nix_search

-- | Runs @nix search@ inside the sandbox (piped through jq, which
-- the base image ships) so results come from the same pinned
-- nixpkgs the sandbox will fetch from.  The image bakes the eval
-- cache, so searches are cheap after the first.
nixSearchTool :: IOE :> es => GroupId -> SandboxRegistry -> Tool es
nixSearchTool gid reg =
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
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "sandbox_id" .= stringField "Sandbox id to search in.",
                  "query" .= stringField "Regex matched against package names and descriptions."
                ],
            "required" .= (["sandbox_id", "query"] :: [Text])
          ],
      toolRun = \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (sid, query) -> do
            let jqProg =
                  "to_entries[:30][] | \"\\(.key|split(\".\")[2:]|join(\".\")) \\(.value.version) \\(.value.description)\""
                cmd =
                  "nix search nixpkgs "
                    <> shellQuote query
                    <> " --json 2>/dev/null | jq -r "
                    <> shellQuote jqProg
            res <- liftIO (execInSandbox reg gid (SandboxId sid) cmd 120)
            pure $ case res of
              Left err -> Left err
              Right er
                | er.erExitCode /= 0 ->
                    Left ("nix search failed (exit " <> T.pack (show er.erExitCode) <> "): " <> er.erStderr)
                | T.null (T.strip er.erStdout) ->
                    Right (object ["results" .= ("" :: Text), "note" .= ("no packages matched; try a broader regex" :: Text)])
                | otherwise ->
                    Right (object ["results" .= er.erStdout, "truncated" .= er.erTruncated])
    }
  where
    parseArgs :: Object -> Parser (Text, Text)
    parseArgs o = (,) <$> o .: "sandbox_id" <*> o .: "query"

--------------------------------------------------------------------------------
-- sandbox_list

listTool :: IOE :> es => TimeZone -> GroupId -> SandboxRegistry -> Tool es
listTool tz gid reg =
  Tool
    { toolName = "sandbox_list",
      toolDescription =
        "List sandboxes available in this group's session (created by you or by other parallel dispatches).",
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties" .= object [],
            "required" .= ([] :: [Text])
          ],
      toolRun = \_args -> do
        entries <- liftIO (listSandboxesForGroup reg gid)
        pure $
          Right $
            toJSON $
              map summarize entries
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

destroyTool :: IOE :> es => GroupId -> SandboxRegistry -> Tool es
destroyTool gid reg =
  Tool
    { toolName = "sandbox_destroy",
      toolDescription =
        "Permanently destroy a sandbox and its /work data (downloaded packages \
        \survive in the shared store).  Use when done, to free resources.",
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "sandbox_id" .= stringField "Sandbox id to destroy."
                ],
            "required" .= (["sandbox_id"] :: [Text])
          ],
      toolRun = \args ->
        case parseEither (withObject "args" (\o -> o .: "sandbox_id")) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (sid :: Text) -> do
            res <- liftIO (destroySandbox reg gid (SandboxId sid))
            pure $ case res of
              Left err -> Left err
              Right () -> Right (object ["ok" .= True])
    }

--------------------------------------------------------------------------------
-- sandbox_read_file

readFileTool :: IOE :> es => GroupId -> SandboxRegistry -> Tool es
readFileTool gid reg =
  Tool
    { toolName = "sandbox_read_file",
      toolDescription =
        "Read up to max_bytes of a text file in a sandbox (path relative to \
        \/work, or absolute; UTF-8, silently truncated at the cap).",
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "sandbox_id" .= stringField "Sandbox id.",
                  "path" .= stringField "File path (relative to /work, or absolute).",
                  "max_bytes"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("Cap (default 16384, max 65536)." :: Text),
                        "default" .= (maxOutputBytes :: Int)
                      ]
                ],
            "required" .= (["sandbox_id", "path"] :: [Text])
          ],
      toolRun = \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (sid, path, mx) -> do
            res <- liftIO (readSandboxFile reg gid (SandboxId sid) path (clampMax mx))
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
      pure (sid, path, maybe maxOutputBytes id mx)
    clampMax n = max 1 (min 65536 n)

--------------------------------------------------------------------------------
-- sandbox_write_file

writeFileTool :: IOE :> es => GroupId -> SandboxRegistry -> Tool es
writeFileTool gid reg =
  Tool
    { toolName = "sandbox_write_file",
      toolDescription =
        "Write a text file in a sandbox (creates parent dirs, overwrites) — \
        \e.g. drop a script before sandbox_exec runs it.",
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "sandbox_id" .= stringField "Sandbox id.",
                  "path" .= stringField "File path (relative to /work, or absolute).",
                  "content" .= stringField "File content (UTF-8 text)."
                ],
            "required" .= (["sandbox_id", "path", "content"] :: [Text])
          ],
      toolRun = \args ->
        case parseEither (withObject "args" parseArgs) args of
          Left e -> pure $ Left ("bad args: " <> T.pack e)
          Right (sid, path, content) -> do
            res <- liftIO (writeSandboxFile reg gid (SandboxId sid) path content)
            pure $ case res of
              Left err -> Left err
              Right () -> Right (object ["ok" .= True, "bytes" .= T.length content])
    }
  where
    parseArgs :: Object -> Parser (Text, Text, Text)
    parseArgs o = (,,) <$> o .: "sandbox_id" <*> o .: "path" <*> o .: "content"

--------------------------------------------------------------------------------
-- Helpers.

stringField :: Text -> Value
stringField desc =
  object
    [ "type" .= ("string" :: Text),
      "description" .= desc
    ]
