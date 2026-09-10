-- | Vision caption transport shared by sticker and transcript workers.
-- Preparation, retry accounting and caption retention belong to the caller.
module Max.Media.Caption (captionImage) where

import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as B64
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Max.Effects.LLM (ChatCtx (..), ChatMessage (..), ChatResponse (..), ContentBlock (..), LLM, chat)
import Max.Http.Failure (renderResponseFailure)
import Max.LLM.Failure (renderLLMFailure)

captionImage :: (LLM :> es) => Text -> Text -> Text -> Text -> ByteString -> Eff es (Either Text Text)
captionImage profile system lead mime bytes = do
  let dataUrl = "data:" <> mime <> ";base64," <> TE.decodeUtf8 (B64.encode bytes)
  result <-
    chat
      (ChatCtx "caption" Nothing Nothing Nothing Nothing Nothing Nothing)
      profile
      [MsgSystem system, MsgUserBlocks [TextBlock lead, ImageDataUrl dataUrl]]
      []
  pure $ case result of
    Left err -> Left ("chat: " <> renderLLMFailure err)
    Right (InterruptedResp _ err) -> Left ("chat interrupted: " <> renderResponseFailure err)
    Right (ToolCallsResp {}) -> Left "chat: unexpected tool calls"
    Right (ContentResp raw)
      | T.null (T.strip raw) -> Left "chat: empty caption"
      | otherwise -> Right (T.strip raw)
