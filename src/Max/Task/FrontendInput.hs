-- | Canonical provenance carried by replies and explicit steering events.
module Max.Task.FrontendInput (FrontendInputView (..), renderFrontendInputs, renderFrontendInputsObserved) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Set (Set)
import Data.Set qualified as Set
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
renderFrontendInputs = renderFrontendInputsObserved Set.empty

renderFrontendInputsObserved :: Set Int64 -> [FrontendInputView] -> Text
renderFrontendInputsObserved _ [] = ""
renderFrontendInputsObserved seen inputs =
  "[前台收件箱：按接收顺序排列的用户输入；来源标签不替代语义判断]\n"
    <> T.intercalate "\n" (map render inputs)
    <> "\n这些是对当前工作的明确反馈。按发送者和回复对象理解，不改变本轮权限。"
  where
    render input =
      TE.decodeUtf8 . LBS.toStrict . encode $
        object $
          [ "message_id" .= input.messageId,
            "kind" .= input.kind,
            "author_principal_id" .= input.author,
            "sender" .= input.sender,
            "received_at" .= input.receivedAt,
            "reply_to" .= input.replyTo
          ]
            <> if Set.member input.messageId seen
              then ["previously_observed" .= True, "body_reference" .= ("message:" <> T.pack (show input.messageId)), "instruction" .= ("这条已观察过的消息现在明确指向本任务；正文见此前观察。" :: Text)]
              else ["body" .= input.body]
