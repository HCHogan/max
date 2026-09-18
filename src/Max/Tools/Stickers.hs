-- | Find captioned stickers by embedding similarity; requires embeddings.
-- Return IDs/descriptions without sending. Replies use [sticker#id], resolved
-- by Max.Sticker through the shared publication path.
module Max.Tools.Stickers
  ( stickerToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Max.Effects.Embedding
  ( Embedding,
    embedBatch,
    renderEmbeddingFault,
  )
import Max.Effects.StickerQuery (StickerQuery, searchStickers)
import Max.Effects.Tools (Tool (..), ToolRunner (..))
import Max.Tools.Schema (stringParam, toolObject)

stickerToolsFor ::
  ( StickerQuery :> es,
    Embedding :> es,
    Log :> es
  ) =>
  [Tool es]
stickerToolsFor = [findStickersTool]

data Candidate = Candidate
  { cId :: !Int64,
    cDescription :: !Text
  }

-- | @find_stickers@: semantic search over the captioned library.
-- Returns a numbered list; sends nothing.
findStickersTool ::
  ( StickerQuery :> es,
    Embedding :> es,
    Log :> es
  ) =>
  Tool es
findStickersTool =
  Tool
    { toolName = "find_stickers",
      toolDescription =
        T.unwords
          [ "在表情包库里按语义搜表情，用来挑一张发。query 描述你想表达的情绪或内容",
            "（如\"嘲讽\"、\"开心的猫猫\"、\"无语\"）。返回若干候选，每个带一个整数 id 和简介。",
            "挑中后在回复里把 [sticker#<id>] 用 [split] 单独隔成一条就会发出去（本工具只搜不发）。"
          ],
      toolSchema = toolObject [("query", stringParam "想表达的情绪/内容，中文短语")] ["query"],
      toolRunner = LegacyRunner $ \args -> case parseEither (withObject "args" (\o -> o .: "query")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (q :: Text) -> run q
    }
  where
    run q = do
      embedded <- embedBatch [q]
      case embedded of
        Left fault -> pure $ Left ("embedding failed: " <> renderEmbeddingFault fault)
        Right [record] -> do
          rows <- searchStickers record
          let cands = [Candidate i d | (i, d) <- rows :: [(Int64, Text)]]
          logInfo "find_stickers" $ object ["query" .= q, "n" .= length cands]
          pure . Right $
            object
              [ "candidates"
                  .= [ object ["id" .= c.cId, "desc" .= c.cDescription]
                     | c <- cands
                     ],
                "hint"
                  .= if null cands
                    then ("库里没有贴切的，就用文字吧" :: Text)
                    else "把其中一个 id 写成 [sticker#<id>] 放进回复即可发出"
              ]
        Right _ -> pure $ Left "embedding failed: bad vector count"
