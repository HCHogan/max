-- | The prompt view of ordered foreground inputs. Storage owns assignment
-- and observation; this pure projection preserves per-message provenance.
module Max.Task.FrontendInput (FrontendInputView (..), renderFrontendInputs) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)

data FrontendInputView = FrontendInputView
  { messageId :: !Int64,
    kind :: !Text,
    author :: !Int64,
    sender :: !(Maybe Text),
    receivedAt :: !UTCTime,
    replyTo :: !(Maybe Int64),
    body :: !Text
  }
  deriving stock (Eq, Show)

renderFrontendInputs :: [FrontendInputView] -> Text
renderFrontendInputs [] = ""
renderFrontendInputs inputs =
  "[前台收件箱：按接收顺序排列的用户输入；来源标签不替代语义判断]\n"
    <> T.intercalate "\n" (map render inputs)
    <> "\n这些输入仍是独立的待处理请求。request_finish 的 inputs 只列本次已明确处理的 message_id 和 disposition；未列出的输入会交给下一轮。"
  where
    render input =
      TE.decodeUtf8 . LBS.toStrict . encode $
        object
          [ "message_id" .= input.messageId,
            "kind" .= input.kind,
            "author_principal_id" .= input.author,
            "sender" .= input.sender,
            "received_at" .= input.receivedAt,
            "reply_to" .= input.replyTo,
            "body" .= input.body
          ]
