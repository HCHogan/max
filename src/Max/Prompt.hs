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
import Max.Session (Session (..))
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

-- | Assemble the system prompt: the @persona@ (from session override
-- or AppConfig default) on top of a fixed format guide describing the
-- marker conventions used in the rendered context.
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

-- | Build the chat context for one @bot trigger:
--
--   * @system@ message: session persona override (or default) + format guide
--   * any prior session history (user/assistant pairs from earlier rounds)
--   * @user@ message: ambient group context (DB recent-N) + reply chain +
--     pending !btw notes (drained from session) + current @-mention.
--
-- The drained notes are returned alongside the messages so the caller
-- can persist the "notes consumed" state back to the session after
-- the LLM call lands.
buildContext ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- default persona (used when session has no override)
  Int -> -- history window size for ambient context
  Session ->
  GroupMessage ->
  Eff es ([ChatMessage], [Text]) -- (messages, drained btw notes)
buildContext defaultPersona n session gm = do
  let GroupId gid = gm.groupId
      MessageId mid = gm.messageId
      UserId selfId' = gm.selfId
      effectivePersona = fromMaybe defaultPersona session.persona
  ambient <- fetchRecentInGroup gid mid n
  replyCtx <- case extractReply gm.message of
    Nothing -> pure Nothing
    Just rid -> fetchMessage rid
  let userBody = renderUser selfId' ambient replyCtx session.btwNotes gm
      messages =
        [ChatMessage "system" (systemPrompt effectivePersona)]
          <> session.history
          <> [ChatMessage "user" userBody]
  pure (messages, session.btwNotes)

renderUser :: Int64 -> [HistoryItem] -> Maybe HistoryItem -> [Text] -> GroupMessage -> Text
renderUser selfId' ambient replyCtx notes gm =
  T.intercalate "\n" $
    concat
      [ ["[群最近上下文]"],
        if null ambient
          then ["(无历史消息)"]
          else map (renderHistoryLine selfId') ambient,
        [""],
        case replyCtx of
          Nothing -> []
          Just r ->
            [ "[引用上下文]",
              renderReplyLine selfId' r,
              ""
            ],
        if null notes
          then []
          else
            [ "[侧记 — 你之前的 !btw 笔记]",
              T.intercalate "\n" (map ("  • " <>) notes),
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
