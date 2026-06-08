module Max.Prompt
  ( -- * Pipeline
    buildContext,

    -- * Building blocks (exposed for tests)
    PromptInputs (..),
    renderContext,
  )
where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Int (Int64)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Log (Log, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.Files (FileRecord (..))
import Max.DB.Files qualified as DBFiles
import Max.DB.History
  ( HistoryItem (..),
    fetchMentionHistory,
    fetchMessage,
    fetchMessagesByIds,
    fetchRecentInGroup,
  )
import Max.Effects.LLM (ChatMessage (..), ContentBlock (..))
import Max.Session (Session (..))
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

-- | Everything 'renderContext' needs in one record.  Splitting the
-- pipeline into 'PromptInputs' + 'renderContext' lets us unit-test the
-- (large) rendering logic against handwritten fixtures without
-- needing Postgres in the loop.
data PromptInputs = PromptInputs
  { -- | Persona from 'AppConfig' — used when 'session.persona' is 'Nothing'.
    defaultPersona :: !Text,
    -- | The active session record (carries persona override + btw notes
    -- + pin list; the field that flows back as "drained notes").
    session :: !Session,
    -- | The @\@-bot@ message that triggered this turn.
    triggerMessage :: !GroupMessage,
    -- | Recent group messages, chronological.  May overlap with
    -- 'mention'; 'renderContext' dedupes by message id.
    ambient :: ![HistoryItem],
    -- | Reconstructed mention/reply history with the bot, chronological.
    mention :: ![HistoryItem],
    -- | Resolved pin list (preserves the user's pin order).
    pinnedItems :: ![HistoryItem],
    -- | If the trigger replied to a message: that message + the files
    -- attached to it (so the model can address them by file_id).
    replyCtx :: !(Maybe (HistoryItem, [FileRecord])),
    -- | Already-loaded data URLs for any images on the current
    -- trigger.  Populated only when the active profile is
    -- multimodal AND the image worker has finished fetching;
    -- otherwise empty and the images remain as @[image:abcd]@
    -- markers in the rendered text.  Format: @data:<mime>;base64,...@.
    triggerImageUrls :: ![Text]
  }

-- | Assemble the system prompt: the @persona@ (from session override
-- or AppConfig default) on top of a fixed format guide describing the
-- marker conventions used in the rendered context.
systemPrompt :: Text -> Text
systemPrompt persona =
  T.unlines
    [ persona,
      "",
      "回复风格（重要）：",
      "  - 你在 QQ 群里跟人说话，不是在写文档；语气像真人，不像 ChatGPT 窗口里答题。",
      "  - 想说多句话时空一行分段，每段尽量短（一两句话）。",
      "  - 禁用 markdown：不要 # 标题、不要 **粗体** / *斜体*、不要 - / * 列表项、不要表格。",
      "  - 只有长代码 / 长引用才用 ``` 代码块；块内随便写。",
      "  - 不开场寒暄、不总结收尾（\"好的我来回答\"、\"希望对你有帮助\"），直接说事。",
      "  - 不要复读用户的问题再回答。",
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

-- | Build the chat context for one @bot trigger.  Runs the DB
-- fetches, then hands off to the pure 'renderContext'.
--
-- When @multimodal@ is 'True', also looks up the local bytes of any
-- image segments on the trigger and embeds them as inline data URLs
-- so the final @user@ message becomes 'MsgUserBlocks' instead of
-- 'MsgUser'.  Falls back gracefully when the image worker hasn't
-- caught up yet — those images stay as @[image:abcd]@ markers.
buildContext ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- default persona (used when session has no override)
  Int -> -- history window size
  Bool -> -- multimodal: load + attach inline images for the trigger
  Session ->
  GroupMessage ->
  Eff es ([ChatMessage], [Text]) -- (messages, drained btw notes)
buildContext defaultPersona n multimodal s gm = do
  let GroupId gid = gm.groupId
      MessageId mid = gm.messageId
      UserId selfId' = gm.selfId
  ambient' <- fetchRecentInGroup gid mid s.clearedAt n
  mention' <- fetchMentionHistory gid selfId' mid s.clearedAt n
  pinnedItems' <- fetchMessagesByIds s.pinned
  replyCtx' <- case extractReply gm.message of
    Nothing -> pure Nothing
    Just rid -> do
      mHist <- fetchMessage rid
      case mHist of
        Nothing -> pure Nothing
        Just h -> do
          files <- DBFiles.fetchFilesForMessage h.messageId
          pure (Just (h, files))
  triggerImageUrls' <-
    if multimodal && hasImageSeg gm.message
      then loadTriggerImageUrls mid
      else pure []
  pure $
    renderContext
      PromptInputs
        { defaultPersona = defaultPersona,
          session = s,
          triggerMessage = gm,
          ambient = ambient',
          mention = mention',
          pinnedItems = pinnedItems',
          replyCtx = replyCtx',
          triggerImageUrls = triggerImageUrls'
        }

-- | True iff there's at least one image segment in the message.
hasImageSeg :: [Segment] -> Bool
hasImageSeg = any isImage
  where
    isImage (SegImage _) = True
    isImage _ = False

-- | Look up image rows for the trigger message via the
-- 'message_images' join table; for each one with a local path
-- present (i.e. the image worker has finished), read the bytes and
-- build a @data:\<mime\>;base64,...@ URL.  Rows where the worker
-- hasn't caught up yet are skipped (caller falls back to the text
-- marker representation).
loadTriggerImageUrls ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Int64 -> -- trigger message_id
  Eff es [Text]
loadTriggerImageUrls mid = do
  rows <-
    query
      "SELECT i.mime_type, i.local_path \
      \  FROM message_images mi \
      \  JOIN images i ON i.sha256 = mi.sha256 \
      \  WHERE mi.message_id = ? \
      \  ORDER BY mi.seg_index"
      (Only mid)
  let pairs = [(mime, path) | (mime, path) <- rows :: [(Text, Text)]]
  fmap concat $ traverse readOne pairs
  where
    readOne (mime, path) = do
      eres <- liftIO (try (BS.readFile (T.unpack path)))
      case eres of
        Right bytes ->
          let b64 = TE.decodeUtf8 (B64.encode bytes)
              url = "data:" <> mime <> ";base64," <> b64
           in pure [url]
        Left (e :: IOException) -> do
          logAttention "prompt: image read failed" $
            object ["path" .= path, "error" .= T.pack (show e)]
          pure []

-- | Pure transformation from fetched inputs to the chat-message list
-- the LLM sees + the (consumed) btw notes the caller should clear off
-- the session.
--
-- Structure:
--
--   * @system@ message: persona + format guide.
--   * Prior mention history reconstructed from the messages table:
--     each prior @-mention becomes a 'MsgUser', each bot LLM reply
--     becomes a 'MsgAssistant', in chronological order.
--   * One final @user@ message containing the ambient group context
--     (chatter NOT directed at the bot), the reply chain (if any),
--     pinned messages, pending !btw notes, and the current
--     @-mention.
--
-- Ambient messages already present in the mention list are dropped
-- to avoid showing the same line twice.
renderContext :: PromptInputs -> ([ChatMessage], [Text])
renderContext pi' =
  let UserId selfId' = pi'.triggerMessage.selfId
      effectivePersona = fromMaybe pi'.defaultPersona pi'.session.persona
      mentionIds = [h.messageId | h <- pi'.mention]
      ambientNoDup =
        [a | a <- pi'.ambient, a.messageId `notElem` mentionIds]
      mentionMessages = map (historyToChat selfId') pi'.mention
      userBody =
        renderUser
          selfId'
          ambientNoDup
          pi'.replyCtx
          pi'.pinnedItems
          pi'.session.btwNotes
          pi'.triggerMessage
      -- If we have inline image bytes for the current trigger,
      -- attach them as a multimodal content-block message;
      -- otherwise fall back to plain text (which still has
      -- @[image:abcd]@ markers in the body).
      userMessage = case pi'.triggerImageUrls of
        [] -> MsgUser userBody
        urls ->
          MsgUserBlocks $
            TextBlock userBody : map ImageDataUrl urls
      messages =
        [MsgSystem (systemPrompt effectivePersona)]
          <> mentionMessages
          <> [userMessage]
   in (messages, pi'.session.btwNotes)

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
renderUser selfId' ambient' replyCtx' pinnedItems' notes gm =
  T.intercalate "\n" $
    concat
      [ -- Pinned first so the model sees them as primary context
        if null pinnedItems'
          then []
          else
            [ "[pin 上下文 — 用户标记需要保留的消息]",
              T.intercalate "\n" (map (renderHistoryLine selfId') pinnedItems'),
              ""
            ],
        ["[群最近上下文]"],
        if null ambient'
          then ["(无历史消息)"]
          else map (renderHistoryLine selfId') ambient',
        [""],
        case replyCtx' of
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
