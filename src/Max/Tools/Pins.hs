-- |
-- Agent-side pin management.  @!pin@/@!unpin@ exist as user commands,
-- but in practice nobody does prospective bookkeeping in a chat — so
-- the model gets the same mutators as tools and curates the pin list
-- itself: pin the spec message it keeps re-searching for, unpin what
-- stopped being relevant.  Silent by design (no group message); the
-- result shows up as the [pinned] block of the next prompt.
module Max.Tools.Pins
  ( pinToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.PinControl (PinControl, pinMessage, unpinMessage)
import Max.Effects.Tools (Tool (..))
import Max.Pin.Policy (PinFailure (..))
import Max.Tools.Schema (integerParam, toolObject)
import Max.Util (tshow)

pinToolsFor :: (PinControl :> es) => [Tool es]
pinToolsFor = [pinTool, unpinTool]

pinTool :: (PinControl :> es) => Tool es
pinTool =
  Tool
    { toolName = "pin_message",
      toolDescription =
        T.unwords
          [ "把一条消息固定进长期上下文：之后每次对话都会看到它（[pinned] 区块，!clear 也不清）。",
            "适合以后还会反复用到的东西——需求/规格、关键决定、要长期参考的图片消息。",
            "典型信号：你发现自己在为同一条消息翻历史。宁缺毋滥，一次性的内容不要 pin。",
            "不需要请示用户，直接 pin 即可。"
          ],
      toolSchema =
        toolObject [("message_id", integerParam "要固定的消息 id（上下文行里的 #<id>）")] ["message_id"],
      toolRun = \args -> case parseEither (withObject "args" parseMessageId) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right mid -> renderResult mid <$> pinMessage mid
    }

unpinTool :: (PinControl :> es) => Tool es
unpinTool =
  Tool
    { toolName = "unpin_message",
      toolDescription =
        T.unwords
          [ "把一条不再需要长期保留的消息移出 [pinned]。",
            "看到里面有过时、已解决或不再相关的内容时，主动清理。"
          ],
      toolSchema =
        toolObject [("message_id", integerParam "要移除的消息 id（[pinned] 行里的 #<id>）")] ["message_id"],
      toolRun = \args -> case parseEither (withObject "args" parseMessageId) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right mid -> renderResult mid <$> unpinMessage mid
    }

renderResult :: Int64 -> Either PinFailure Int -> Either Text Value
renderResult message = \case
  Right count -> Right (object ["ok" .= True, "pin_count" .= count])
  Left PinCallerFenced -> Left "当前回合已失去执行权限"
  Left PinNotVisible -> Left ("找不到 message_id=" <> tshow message)
  Left (PinAtCapacity count) -> Left ("pin 已达上限（" <> tshow count <> " 条）；先用 unpin_message 清掉不再需要的")
  Left PinNotPresent -> Left ("message_id=" <> tshow message <> " 不在 pin 列表里")

parseMessageId :: Object -> Parser Int64
parseMessageId o = o .: "message_id"
