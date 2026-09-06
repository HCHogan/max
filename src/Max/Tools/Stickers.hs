-- |
-- Sticker retrieval tool for the agent, over the library the bot
-- accumulates by watching the group (see "Max.DB.Stickers" /
-- "Max.Stickers").
--
--   * @find_stickers@ — the model gives a free-text mood/content query;
--     we embed it, cosine-search the captioned library, and return the
--     closest matches as a numbered list of @{id, desc}@.  Nothing is
--     sent.
--
-- Sending is no longer a tool: the model writes @[sticker#\<id\>]@ inline
-- in its reply and the reply post-processor turns that into a real
-- sticker segment ('Max.Sticker.resolveSticker', called from
-- 'Max.Handler.sendAndPersistReply').  Inbound history renders stickers
-- as @[sticker#\<id\>: …]@, so the id the model reads is the same handle
-- it writes back — one form in and out.  An explicit integer handle
-- keeps sending unambiguous (the old free-text auto-send made the model
-- learn to just *type* captions).
--
-- Only registered when an embedding client is configured: without
-- vectors there is no retrieval.
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
import Max.Effects.Embedding (Embedding, embedBatch, renderEmbeddingFault)
import Max.Effects.StickerQuery (StickerQuery, searchStickers)
import Max.Effects.Tools (Tool (..))
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
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "query")) args of
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
