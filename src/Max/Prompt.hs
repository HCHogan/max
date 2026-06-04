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
import Max.DB.Files (FileRecord (..))
import Max.DB.Files qualified as DBFiles
import Max.DB.History
  ( HistoryItem (..),
    fetchMentionHistory,
    fetchMessage,
    fetchMessagesByIds,
    fetchRecentInGroup,
  )
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
      "  [file:<name>]               — 一个群文件；用 list_recent_files 或 import_file_to_sandbox 处理",
      "  [forward]                   — 转发的聊天记录（你看不到内容）",
      "",
      "当用户引用了带文件的消息时，引用块下面会附带一段 `附带文件:`，",
      "列出该消息里每个文件的 file_id / name / size / ready 状态。用",
      "其中的 file_id 直接调 import_file_to_sandbox，不需要先 list_recent_files。",
      "",
      "群成员可以用 !pin 把过去的某条消息标记保留——这些会单独显示在",
      "[pin 上下文] 段；即使用户 !clear 也不会消失。这是用户给的明确",
      "提示，请认真当成对话背景。"
    ]

-- | Build the chat context for one @bot trigger.
--
-- Structure:
--
--   * @system@ message: persona + format guide.
--   * Prior mention history reconstructed from the messages table:
--     each prior @-mention becomes a 'MsgUser', each bot LLM reply
--     becomes a 'MsgAssistant', in chronological order.  Pinned
--     messages and the watermark ('clearedAt') determine inclusion.
--   * One final @user@ message containing the ambient group context
--     (chatter NOT directed at the bot), the reply chain (if any),
--     pinned messages, pending !btw notes, and the current
--     @-mention.
--
-- The drained notes are returned alongside the messages so the
-- caller can persist the "notes consumed" state back to the
-- session.
buildContext ::
  (WithConnection :> es, IOE :> es) =>
  Text -> -- default persona (used when session has no override)
  Int -> -- history window size
  Session ->
  GroupMessage ->
  Eff es ([ChatMessage], [Text]) -- (messages, drained btw notes)
buildContext defaultPersona n session gm = do
  let GroupId gid = gm.groupId
      MessageId mid = gm.messageId
      UserId selfId' = gm.selfId
      effectivePersona = fromMaybe defaultPersona session.persona
  ambient <- fetchRecentInGroup gid mid session.clearedAt n
  mention <- fetchMentionHistory gid selfId' mid session.clearedAt n
  pinnedItems <- fetchMessagesByIds session.pinned
  replyCtx <- case extractReply gm.message of
    Nothing -> pure Nothing
    Just rid -> do
      mHist <- fetchMessage rid
      case mHist of
        Nothing -> pure Nothing
        Just h -> do
          files <- DBFiles.fetchFilesForMessage h.messageId
          pure (Just (h, files))
  -- The ambient list still might contain @-mention rows (the SQL
  -- doesn't filter them out; they'll already appear as part of
  -- 'mention').  Drop those from ambient by message_id to avoid
  -- showing the same message twice.
  let mentionIds = [h.messageId | h <- mention]
      ambientNoDup =
        [a | a <- ambient, a.messageId `notElem` mentionIds]
      mentionMessages = map (historyToChat selfId') mention
      userBody =
        renderUser
          selfId'
          ambientNoDup
          replyCtx
          pinnedItems
          session.btwNotes
          gm
      messages =
        [MsgSystem (systemPrompt effectivePersona)]
          <> mentionMessages
          <> [MsgUser userBody]
  pure (messages, session.btwNotes)

-- | Reconstruct one bot/user turn as an OpenAI/Anthropic ChatMessage.
-- A row sent by the bot becomes 'MsgAssistant'; everything else
-- (members @-ing the bot) becomes 'MsgUser' with a sender-prefixed
-- body so the model knows who's talking when multiple members
-- address the bot.
historyToChat :: Int64 -> HistoryItem -> ChatMessage
historyToChat botId h
  | h.userId == botId = MsgAssistant h.renderedText
  | otherwise =
      let name = fromMaybe (T.pack (show h.userId)) h.senderNickname
       in MsgUser ("<" <> name <> ">: " <> h.renderedText)

renderUser ::
  Int64 ->
  [HistoryItem] ->
  Maybe (HistoryItem, [FileRecord]) ->
  [HistoryItem] -> -- pinned items, in user pin order
  [Text] ->
  GroupMessage ->
  Text
renderUser selfId' ambient replyCtx pinnedItems notes gm =
  T.intercalate "\n" $
    concat
      [ -- Pinned first so the model sees them as primary context
        if null pinnedItems
          then []
          else
            [ "[pin 上下文 — 用户标记需要保留的消息]",
              T.intercalate "\n" (map (renderHistoryLine selfId') pinnedItems),
              ""
            ],
        ["[群最近上下文]"],
        if null ambient
          then ["(无历史消息)"]
          else map (renderHistoryLine selfId') ambient,
        [""],
        case replyCtx of
          Nothing -> []
          Just (r, files) ->
            "[引用上下文]" : renderReplyLine selfId' r : renderReplyFiles files <> [""],
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

renderReplyFiles :: [FileRecord] -> [Text]
renderReplyFiles [] = []
renderReplyFiles xs = "  附带文件:" : map fileLine xs
  where
    fileLine r =
      "    - file_id="
        <> tquote r.frFileId
        <> ", name="
        <> tquote r.frFileName
        <> sizePart r.frBytesSize
        <> ", ready="
        <> (case r.frLocalPath of Just _ -> "true"; Nothing -> "false")
    sizePart Nothing = ""
    sizePart (Just n) = ", bytes=" <> T.pack (show n)
    tquote t = "\"" <> t <> "\""

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
