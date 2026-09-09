-- |
-- Compatibility entry point for evidence-triggered memory maintenance.
-- Episode capture lives in Max.Historian; the legacy parser remains available
-- for historical payloads, but cannot authorize current maintenance writes.
module Max.MemoryExtract
  ( dreamWorker,

    -- * Exposed for tests
    ExtractOp (..),
    parseOps,
  )
where

import Data.Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone)
import Effectful
import Effectful.Concurrent (Concurrent)
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.LLM (LLM)
import Max.Memory.Maintenance (memoryMaintenanceWorker)
import Max.MemoryStore (MemoryId (..), MemoryVersion (..))

-- | One operation the extractor model may emit.
data ExtractOp
  = OpAdd !Text !(Maybe Int64) !Text -- scope, user_id (scope=user), content
  | OpUpdate !MemoryId !MemoryVersion !Text !Text
  | OpArchive !MemoryId !MemoryVersion !Text
  | OpSupersede !MemoryId !MemoryVersion !MemoryId !Text
  deriving stock (Show, Eq)

instance FromJSON ExtractOp where
  parseJSON = withObject "op" $ \o -> do
    action <- o .: "action"
    case action :: Text of
      "add" -> OpAdd <$> o .: "scope" <*> o .:? "user_id" <*> o .: "content"
      "update" ->
        OpUpdate
          <$> o .: "id"
          <*> o .: "version"
          <*> o .: "content"
          <*> (fromMaybe "legacy maintenance update" <$> o .:? "reason")
      "delete" -> parseArchive "legacy maintenance delete" o
      "archive" -> parseArchive "maintenance archive" o
      "supersede" ->
        OpSupersede
          <$> o .: "id"
          <*> o .: "version"
          <*> o .: "replacement_id"
          <*> (fromMaybe "maintenance supersede" <$> o .:? "reason")
      other -> fail ("unknown action: " <> T.unpack other)
    where
      parseArchive fallback o =
        OpArchive
          <$> o .: "id"
          <*> o .: "version"
          <*> (fromMaybe fallback <$> o .:? "reason")

-- | Parse the model's output into ops: strip code fences, find the
-- first @[@ .. last @]@, decode.
parseOps :: Text -> Either String [ExtractOp]
parseOps raw =
  let t = T.strip (stripFences (T.strip raw))
      sliced = case (T.findIndex (== '[') t, T.length t - 1) of
        (Just i, _) -> T.drop i (T.dropWhileEnd (/= ']') t)
        _ -> t
   in eitherDecode (LBS.fromStrict (TE.encodeUtf8 sliced))
  where
    stripFences s
      | "```" `T.isPrefixOf` s =
          T.intercalate "\n"
            . takeWhile (not . ("```" `T.isPrefixOf`))
            . drop 1
            $ T.lines s
      | otherwise = s

-- The old nightly cardinality heuristic is superseded by durable causal work.
dreamWorker :: (LLM :> es, Concurrent :> es, WithConnection :> es, Log :> es, IOE :> es) => Text -> Text -> TimeZone -> Int -> Eff es ()
dreamWorker = memoryMaintenanceWorker
