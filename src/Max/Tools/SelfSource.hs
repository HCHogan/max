-- |
-- Read-only inspection of the exact public source snapshot embedded in the
-- running binary.  One action-shaped tool keeps the model-visible schema small
-- while still supporting discovery, literal search, and bounded line reads.
module Max.Tools.SelfSource (selfSourceTools) where

import Data.Aeson
import Data.Aeson.Types (Pair, Parser, parseEither)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Max.BuildInfo (gitRev)
import Max.Effects.Tools (Tool (..))
import Max.SelfSource

selfSourceTools :: [Tool es]
selfSourceTools = [inspectSourceTool]

inspectSourceTool :: Tool es
inspectSourceTool =
  Tool
    { toolName = "inspect_source",
      toolDescription =
        T.unwords
          [ "Inspect the exact public Max source snapshot embedded in this binary.",
            "Use search for symbols/text, read for bounded path:line source, and tree for discovery.",
            "It cannot read runtime config, secrets, database state, or arbitrary host files;",
            "source defaults are not evidence of the production effective configuration."
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "action"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "enum" .= (["search", "read", "tree"] :: [Text])
                      ],
                  "query"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("search: case-insensitive literal code/text" :: Text)
                      ],
                  "path"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("read: exact path; tree: optional directory prefix" :: Text)
                      ],
                  "path_prefix"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("search: optional directory/file prefix" :: Text)
                      ],
                  "start_line"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "minimum" .= (1 :: Int),
                        "default" .= (1 :: Int)
                      ],
                  "line_count"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "minimum" .= (1 :: Int),
                        "maximum" .= (240 :: Int),
                        "default" .= (120 :: Int)
                      ],
                  "limit"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "minimum" .= (1 :: Int),
                        "maximum" .= (300 :: Int),
                        "default" .= (20 :: Int)
                      ]
                ],
            "required" .= (["action"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "inspect_source args" parseRequest) args of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right request -> pure (runRequest request)
    }

data InspectRequest = InspectRequest
  { irAction :: !Text,
    irQuery :: !(Maybe Text),
    irPath :: !(Maybe Text),
    irPathPrefix :: !(Maybe Text),
    irStartLine :: !Int,
    irLineCount :: !Int,
    irLimit :: !Int
  }

parseRequest :: Object -> Parser InspectRequest
parseRequest o =
  InspectRequest
    <$> o .: "action"
    <*> o .:? "query"
    <*> o .:? "path"
    <*> o .:? "path_prefix"
    <*> (fromMaybe 1 <$> o .:? "start_line")
    <*> (fromMaybe 120 <$> o .:? "line_count")
    <*> (fromMaybe 20 <$> o .:? "limit")

runRequest :: InspectRequest -> Either Text Value
runRequest request = case request.irAction of
  "search" -> do
    query <- maybe (Left "search requires query") Right request.irQuery
    matches <- searchSource query request.irPathPrefix request.irLimit
    pure . object $
      snapshotFields
        <> [ "action" .= ("search" :: Text),
             "query" .= T.strip query,
             "results" .= map matchJson matches
           ]
  "read" -> do
    path <- maybe (Left "read requires path") Right request.irPath
    slice <- readSource path request.irStartLine request.irLineCount
    pure . object $
      snapshotFields
        <> [ "action" .= ("read" :: Text),
             "path" .= slice.ssPath,
             "start_line" .= slice.ssStartLine,
             "end_line" .= slice.ssEndLine,
             "total_lines" .= slice.ssTotalLines,
             "next_line" .= slice.ssNextLine,
             "content" .= slice.ssContent
           ]
  "tree" -> do
    let prefix = fromMaybe "" request.irPath
    (paths, truncated) <- sourcePaths prefix request.irLimit
    pure . object $
      snapshotFields
        <> [ "action" .= ("tree" :: Text),
             "path" .= T.strip prefix,
             "files" .= paths,
             "truncated" .= truncated
           ]
  other -> Left ("unknown action: " <> other <> "; expected search, read, or tree")

snapshotFields :: [Pair]
snapshotFields =
  [ "git_revision" .= fromMaybe "unknown" gitRev,
    "bundle_hash" .= sourceBundleHash,
    "file_count" .= sourceFileCount,
    "source_bytes" .= sourceByteCount
  ]

matchJson :: SourceMatch -> Value
matchJson match =
  object
    [ "path" .= match.smPath,
      "line" .= match.smLine,
      "snippet" .= match.smSnippet
    ]
