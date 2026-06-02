module Max.Prompt
  ( buildContext,
  )
where

import Data.Int (Int64)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.History (HistoryItem (..), fetchMessage, fetchRecentInGroup)
import Max.Effects.LLM (ChatMessage (..))
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

-- | Assemble the system prompt: the caller-supplied @persona@ on top
-- of a fixed format guide describing the marker conventions used in
-- the rendered context.
systemPrompt :: Text -> Text
systemPrompt persona =
  T.unlines
    [ persona,
      "",
      "上下文格式：",
      "  [HH:MM <昵称>]: 内容        — 群里的一条普通消息",
      "  [↩ 引用 HH:MM <昵称>]: ...   — 用户引用了某条历史消息",
      "  [image:abcd1234]            — 一张图片（你看不到内容，可以请用户描述）",
      "  [forward]                   — 转发的聊天记录（你看不到内容）"
    ]

-- | Build the chat context for one @bot trigger as a single-turn prompt:
--   - one @system@ message with persona + format key
--   - one @user@ message containing recent group context + reply context
--     + the triggering message + an explicit ask
buildContext ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- persona
  Int -> -- history window size
  GroupMessage ->
  Eff es [ChatMessage]
buildContext persona n gm = do
  let GroupId gid = gm.groupId
      MessageId mid = gm.messageId
      UserId selfId' = gm.selfId
  history <- fetchRecentInGroup gid mid n
  replyCtx <- case extractReply gm.message of
    Nothing -> pure Nothing
    Just rid -> fetchMessage rid
  let body = renderBody selfId' history replyCtx gm
  pure
    [ ChatMessage "system" (systemPrompt persona),
      ChatMessage "user" body
    ]

renderBody :: Int64 -> [HistoryItem] -> Maybe HistoryItem -> GroupMessage -> Text
renderBody selfId' history replyCtx gm =
  T.intercalate "\n" $
    concat
      [ ["[群最近上下文]"],
        if null history
          then ["(无历史消息)"]
          else map (renderHistoryLine selfId') history,
        [""],
        case replyCtx of
          Nothing -> []
          Just r ->
            [ "[引用上下文]",
              renderReplyLine selfId' r,
              ""
            ],
        [ "[当前 @ 你的消息]",
          renderCurrentLine gm,
          "",
          "请回复当前消息。"
        ]
      ]

renderHistoryLine :: Int64 -> HistoryItem -> Text
renderHistoryLine selfId' h =
  let name = displayName selfId' h.userId h.senderNickname
   in "[" <> formatHM h.receivedAt <> " " <> name <> "]: " <> oneLine h.renderedText

renderReplyLine :: Int64 -> HistoryItem -> Text
renderReplyLine selfId' h =
  let name = displayName selfId' h.userId h.senderNickname
   in "[↩ 引用 " <> formatHM h.receivedAt <> " " <> name <> "]: " <> oneLine h.renderedText

renderCurrentLine :: GroupMessage -> Text
renderCurrentLine gm =
  let UserId uid = gm.userId
      Sender _ nick _ = gm.sender
      name = fromMaybe (T.pack (show uid)) nick
      txt = stripBotMention gm.selfId (renderPlainText gm.message)
   in "<" <> name <> ">: " <> T.strip txt

stripBotMention :: UserId -> Text -> Text
stripBotMention (UserId u) = T.replace ("@" <> T.pack (show u)) ""

displayName :: Int64 -> Int64 -> Maybe Text -> Text
displayName selfId' uid mNick
  | uid == selfId' = "Max"
  | otherwise = fromMaybe (T.pack (show uid)) mNick

formatHM :: UTCTime -> Text
formatHM = T.pack . formatTime defaultTimeLocale "%H:%M"

oneLine :: Text -> Text
oneLine = T.replace "\n" " ⏎ "

extractReply :: [Segment] -> Maybe Int64
extractReply segs = listToMaybe [m | SegReply (MessageId m) <- segs]
