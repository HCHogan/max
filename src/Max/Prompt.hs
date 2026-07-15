module Max.Prompt
  ( -- * Pipeline
    buildContext,

    -- * Building blocks (exposed for tests)
    PromptInputs (..),
    PromptImage (..),
    renderContext,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Database.PostgreSQL.Simple (In (..), Only (..))
import Effectful
import Effectful.Log (Log, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection, query)
import Max.DB.Files (FileRecord (..))
import Max.DB.Files qualified as DBFiles
import Max.DB.History
  ( HistoryItem (..),
    bestName,
    fetchForwardChildren,
    fetchMentionHistory,
    fetchMessage,
    fetchMessagesByIds,
    fetchRecentInGroup,
  )
import Max.DB.Memory (MemoryItem (..), MemoryScope (..), listMemories)
import Max.Effects.LLM (ChatMessage (..), ContentBlock (..))
import Max.Images (downloadableImageCount)
import Max.Session (Session (..))
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)
import System.FilePath ((</>))

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
    -- | If the trigger replied to a message: that message, the files
    -- attached to it (so the model can address them by file_id), and
    -- — when the quoted message is a 转发聊天记录 — its stored
    -- contents, so quoting a forward makes it readable.
    replyCtx :: !(Maybe (HistoryItem, [FileRecord], [HistoryItem])),
    -- | Whether the active profile accepts image content blocks.
    -- Toggles the format-guide wording for the @[image]@ marker.
    multimodal :: !Bool,
    -- | Long-term memories of this group, oldest first.
    groupMemories :: ![MemoryItem],
    -- | Long-term memories of the *triggering* user (cross-group),
    -- oldest first.  Other members' memories are not injected — the
    -- model can @memory_list@ them when actually relevant.
    userMemories :: ![MemoryItem],
    -- | Already-loaded images to attach to the final user message,
    -- in display order (context images chronological, trigger's
    -- last).  Populated only when 'multimodal' AND the image worker
    -- has finished fetching; otherwise empty and images remain as
    -- @[image]@ markers in the rendered text.
    images :: ![PromptImage],
    -- | Wall-clock time this turn is being built.  Feeds the system
    -- prompt's environment block so the model knows the current
    -- date/time — context lines only carry HH:MM, no date.
    now :: !UTCTime
  }

-- | One inline image for the final user message: a data URL plus a
-- text label naming the source message (\"[HH:MM \<昵称\>] 消息里的
-- 图片:\") so the model can tie it back to a rendered context line.
data PromptImage = PromptImage
  { piLabel :: !Text,
    -- | @data:\<mime\>;base64,...@
    piDataUrl :: !Text
  }
  deriving stock (Show, Eq)

-- | Assemble the system prompt: the @persona@ (from session override
-- or AppConfig default), a scene block saying whether this is a
-- group or a one-on-one chat (kept out of the persona so configured
-- personas stay scene-agnostic), the environment, a fixed format
-- guide, and the long-term memory block (if any) appended *last* —
-- end-of-prompt placement keeps it low-salience relative to the
-- persona and the live conversation, which is deliberate: memories
-- are background, not agenda.
systemPrompt ::
  Bool -> -- multimodal
  Bool -> -- private chat
  Text -> -- environment block
  Text -> -- persona
  Maybe Text -> -- memory block
  Text
systemPrompt multimodal' private envText persona mMemBlock =
  T.unlines $
    [ persona,
      "",
      if private
        then
          "对话场景：QQ 一对一私聊。对方的每条消息都是直接对你说的，\
          \正常对话即可；没有其他人在看。"
        else
          "对话场景：QQ 群聊。你同时面对多名群成员，上下文里 [HH:MM <昵称>] \
          \前缀标明谁在说话；大部分消息是成员之间的闲聊，只有 @你 或引用你的\
          \消息才是在叫你。",
      "",
      envText,
      "",
      "回复风格（重要）：",
      "  - 你在 QQ 上跟人聊天（群聊或私聊），不是在写文档；语气像真人，不像 ChatGPT 窗口里答题。",
      "  - 想说多句话时空一行分段，每段尽量短（一两句话）。每个空行隔开的段",
      "    会作为单独一条消息发出（``` 代码块不会被拆开），像真人连发几条",
      "    短消息那样。",
      "  - 禁用 markdown：不要 # 标题、不要 **粗体** / *斜体*、不要 - / * 列表项、不要表格。",
      "  - 只有长代码 / 长引用才用 ``` 代码块；块内随便写。",
      "  - 不开场寒暄、不总结收尾（\"好的我来回答\"、\"希望对你有帮助\"），直接说事。",
      "  - 不要复读用户的问题再回答。",
      "",
      "上下文格式：",
      "  [HH:MM <昵称>]: 内容        — 一条历史消息",
      "  [↩ 引用 HH:MM <昵称>]: ...   — 用户引用了某条历史消息",
      if multimodal'
        then "  [image]                     — 一张图片；内容会附在消息末尾，标注来自哪条消息（[HH:MM <昵称>] 消息里的图片）。太老或太多的图会被略去，只剩标记"
        else "  [image]                     — 一张图片（你看不到内容，可以请用户描述）",
      "  [file:<name>]               — 一个群文件；用 list_recent_files 或 import_file_to_sandbox 处理",
      "  [forward]                   — 转发的聊天记录；用户引用它时，内容会展开在 [引用上下文] 的 转发记录内容 里",
      "  @<数字>                     — @某人（数字是 QQ 号）；对应谁看 [当前环境] 的成员对照",
      "",
      "当用户引用了带文件的消息时，引用块下面会附带一段 `附带文件:`，",
      "列出该消息里每个文件的 file_id / name / size / ready 状态。用",
      "其中的 file_id 直接调 import_file_to_sandbox，不需要先 list_recent_files。",
      "",
      "用户可以用 !pin 把过去的某条消息标记保留——这些会单独显示在",
      "[pin 上下文] 段；即使用户 !clear 也不会消失。这是用户给的明确",
      "提示，请认真当成对话背景。",
      "",
      "干长活时的播报（say 工具）：",
      "  - 群友看不到你的工具调用，只能看到沉默。任务要跑好几步时，用 say",
      "    随手报进展：开工说一句、关键步骤成败说一句、改主意说一句；",
      "    连续闷头调了差不多 5 轮工具还没完，也该冒一句现在在干嘛。",
      "  - 每次一行短话就行，别拿 say 发最终答案。",
      "",
      "长期记忆（memory_* 工具）：",
      "  - 只存将来的对话还会用到的稳定信息（身份、偏好、约定、长期项目）。",
      "    闲聊、一次性任务的细节、翻群消息能查到的东西都不要存。",
      "    大多数对话不需要动记忆。",
      "  - 发现记忆过时或重复时，用 memory_update 改、memory_forget 删，",
      "    不要越攒越多。",
      "  - 存了记忆不用在回复里宣布（群友可以用 !memory 查看和删除）。"
    ]
      <> maybe [] (\b -> ["", b]) mMemBlock

-- | Build the chat context for one @bot trigger.  Runs the DB
-- fetches, then hands off to the pure 'renderContext'.
--
-- When @multimodal@ is 'True', also looks up the local bytes of
-- images on the trigger AND on context messages (reply target, pins,
-- recent history) and embeds them as inline data URLs so the final
-- @user@ message becomes 'MsgUserBlocks' instead of 'MsgUser'.
-- Falls back gracefully when the image worker hasn't caught up yet —
-- those images stay as @[image]@ markers.
buildContext ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- default persona (used when session has no override)
  Int -> -- history window size
  Bool -> -- multimodal: load + attach inline images
  FilePath -> -- blob store root ('AppConfig.imagesDir'); images.local_path is relative to it
  Session ->
  GroupMessage ->
  Eff es ([ChatMessage], [Text]) -- (messages, drained btw notes)
buildContext defaultPersona n multimodal' blobRoot s gm = do
  let GroupId gid = gm.groupId
      MessageId mid = gm.messageId
      UserId selfId' = gm.selfId
      UserId senderId = gm.userId
  -- In a private chat every message is part of the bot conversation:
  -- the full recent history becomes the structured user/assistant
  -- turn list, and the ambient section (chatter *not* directed at the
  -- bot) is empty by definition.
  ambient' <-
    if isPrivateChat gm.groupId
      then pure []
      else fetchRecentInGroup gid mid s.clearedAt n
  mention' <-
    if isPrivateChat gm.groupId
      then fetchRecentInGroup gid mid s.clearedAt n
      else fetchMentionHistory gid selfId' mid s.clearedAt n
  pinnedItems' <- fetchMessagesByIds s.pinned
  groupMems <- listMemories ScopeGroup gid
  userMems <- listMemories ScopeUser senderId
  replyCtx' <- case extractReply gm.message of
    Nothing -> pure Nothing
    Just rid -> do
      mHist <- fetchMessage rid
      case mHist of
        Nothing -> pure Nothing
        Just h -> do
          files <- DBFiles.fetchFilesForMessage h.messageId
          -- Expand a quoted 转发聊天记录: its contents were filed by
          -- the forward worker as child rows.  Empty for ordinary
          -- messages — one cheap indexed lookup either way.
          kids <- fetchForwardChildren h.messageId maxForwardLines
          pure (Just (h, files, kids))
  images' <-
    if multimodal'
      then do
        -- The trigger's images were enqueued moments ago and may
        -- still be downloading — hold the turn until they land so
        -- the model actually sees them.  (Older context images are
        -- either long since fetched or permanently failed; no point
        -- waiting on those.)
        let expected = downloadableImageCount gm.message
        when (expected > 0) $ waitForTriggerImages mid expected
        -- Budget priority: the reply target is what the user is
        -- pointing at, pins are explicit user signals, then plain
        -- recency.  (Display order is chronological regardless —
        -- 'loadPromptImages' re-sorts.)
        let replyItems = maybe [] (\(r, _, kids) -> r : kids) replyCtx'
            candidates =
              dedupById $
                replyItems
                  <> pinnedItems'
                  <> sortOn (Down . (.receivedAt)) (ambient' <> mention')
        loadPromptImages
          blobRoot
          selfId'
          mid
          (Set.fromList (map (.messageId) replyItems))
          candidates
      else pure []
  now' <- liftIO getCurrentTime
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
          multimodal = multimodal',
          groupMemories = groupMems,
          userMemories = userMems,
          images = images',
          now = now'
        }

-- | Poll until the image worker has recorded all of the trigger's
-- downloadable images ('message_images' rows are inserted only after
-- a download completes), so the prompt doesn't race the fetch and
-- silently drop the picture the user is asking about.  Bounded: a
-- failed download never inserts its row, so we give up after
-- 'waitImagesMaxMs' and build the prompt with whatever landed.
waitForTriggerImages ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Int64 -> -- trigger message_id
  Int -> -- expected downloadable image count
  Eff es ()
waitForTriggerImages mid expected = go 0
  where
    stepMs = 300
    waitImagesMaxMs = 30_000
    go elapsed
      | elapsed >= waitImagesMaxMs =
          logAttention "prompt: trigger images still missing after wait" $
            object ["message_id" .= mid, "expected" .= expected]
      | otherwise = do
          rows <-
            query
              "SELECT count(*) FROM message_images WHERE message_id = ?"
              (Only mid)
          case rows of
            [Only (n :: Int64)] | n >= fromIntegral expected -> pure ()
            _ -> do
              liftIO (threadDelay (stepMs * 1000))
              go (elapsed + stepMs)

-- | Keep the first (name) entry per user id.
dedupeRoster :: [(Int64, Text)] -> [(Int64, Text)]
dedupeRoster = go Set.empty
  where
    go _ [] = []
    go seen ((u, n) : rest)
      | u `Set.member` seen = go seen rest
      | otherwise = (u, n) : go (Set.insert u seen) rest

-- | Keep first occurrence of each message id.
dedupById :: [HistoryItem] -> [HistoryItem]
dedupById = go Set.empty
  where
    go _ [] = []
    go seen (h : rest)
      | h.messageId `Set.member` seen = go seen rest
      | otherwise = h : go (Set.insert h.messageId seen) rest

-- | Total images attached to one prompt.  Keeps worst-case context
-- growth bounded (8 × ~1 MiB of base64) while covering the common
-- "look at these screenshots" flows.
maxPromptImages :: Int
maxPromptImages = 8

-- | Per-image byte cap; anything larger is skipped (stays a text
-- marker) rather than blowing up the request body.  NB: some
-- endpoints cap lower than this (e.g. Anthropic at 5 MB/image) and
-- will reject the request themselves.
maxImageBytes :: Int
maxImageBytes = 20 * 1024 * 1024

-- | Load up to 'maxPromptImages' images for the trigger + context
-- messages via one 'message_images' join.  The trigger's images
-- claim the budget first, then @candidates@ in the given priority
-- order.  Selected context images are re-sorted chronologically for
-- display and the trigger's go last, closest to the question.
-- Images whose local file is missing (worker hasn't caught up) or
-- oversized are skipped.
loadPromptImages ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  FilePath -> -- blob store root; images.local_path is relative to it
  Int64 -> -- bot self id (for display names in labels)
  Int64 -> -- trigger message_id
  Set.Set Int64 -> -- message ids belonging to the quoted reply (incl. forward children)
  [HistoryItem] -> -- context candidates, priority order, deduped
  Eff es [PromptImage]
loadPromptImages blobRoot selfId' mid replyIds candidates = do
  let candidates' = filter (\h -> h.messageId /= mid) candidates
      ids = mid : map (.messageId) candidates'
  rows <-
    query
      "SELECT mi.message_id, i.mime_type, i.local_path \
      \  FROM message_images mi \
      \  JOIN images i ON i.sha256 = mi.sha256 \
      \  WHERE mi.message_id IN ? \
      \  ORDER BY mi.message_id, mi.seg_index"
      (Only (In ids))
  let byMsg =
        Map.fromListWith
          (flip (<>))
          [(m, [(mime, path)]) | (m, mime, path) <- rows :: [(Int64, Text, Text)]]
      imagesOf i = Map.findWithDefault [] i byMsg
      picked =
        take maxPromptImages $
          map Left (imagesOf mid)
            <> [Right (h, mp) | h <- candidates', mp <- imagesOf h.messageId]
      contextPicked = sortOn (\(h, _) -> h.receivedAt) [hp | Right hp <- picked]
      triggerPicked = [mp | Left mp <- picked]
  ctxImgs <- fmap concat $ traverse (uncurry loadCtx) contextPicked
  trigImgs <- fmap concat $ traverse (loadOne "[当前消息] 里的图片:") triggerPicked
  pure (ctxImgs <> trigImgs)
  where
    loadCtx h mp =
      -- The quoted message's images get an unmistakable label — "which
      -- picture are you asking about" must not depend on the model
      -- correlating timestamps.
      let label
            | h.messageId `Set.member` replyIds =
                "[↩ 被引用的那条消息（"
                  <> formatHM h.receivedAt
                  <> " "
                  <> displayName selfId' h
                  <> "）] 里的图片:"
            | otherwise =
                "["
                  <> formatHM h.receivedAt
                  <> " "
                  <> displayName selfId' h
                  <> "] 消息里的图片:"
       in loadOne label mp
    loadOne label (mime, path) = do
      -- images.local_path is stored relative to the blob root
      -- (that's what the image worker writes); resolve before reading.
      eres <- liftIO (try (BS.readFile (blobRoot </> T.unpack path)))
      case eres of
        Right bytes
          | BS.length bytes > maxImageBytes -> do
              logAttention "prompt: image skipped (too large)" $
                object ["path" .= path, "bytes" .= BS.length bytes]
              pure []
          | otherwise ->
              let b64 = TE.decodeUtf8 (B64.encode bytes)
               in pure [PromptImage label ("data:" <> mime <> ";base64," <> b64)]
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
      GroupId gidRaw = pi'.triggerMessage.groupId
      UserId senderId = pi'.triggerMessage.userId
      senderName = senderDisplayName pi'.triggerMessage
      memBlock =
        renderMemories
          (isPrivateChat pi'.triggerMessage.groupId)
          senderName
          pi'.groupMemories
          pi'.userMemories
      effectivePersona = fromMaybe pi'.defaultPersona pi'.session.persona
      -- Everyone appearing in this turn's context, QQ号 ↔ display
      -- name.  Rendered text shows mentions as raw @<QQ号> (that's
      -- all the wire event carries), so without this table the model
      -- cannot tell who @123456 is — including itself.
      roster =
        dedupeRoster $
          (selfId', "Max（你自己）")
            : (senderId, senderName)
            : [ (h.userId, displayName selfId' h)
              | h <-
                  pi'.mention
                    <> pi'.ambient
                    <> pi'.pinnedItems
                    <> maybe [] (\(r, _, _) -> [r]) pi'.replyCtx,
                h.userId /= selfId'
              ]
      envText =
        T.intercalate "\n" $
          [ "[当前环境]",
            "  现在：" <> formatEnvTime pi'.now,
            if isPrivateChat pi'.triggerMessage.groupId
              then "  场景：与 " <> senderName <> "（QQ " <> T.pack (show senderId) <> "）私聊"
              else "  群号：" <> T.pack (show gidRaw),
            "  当前模型：" <> pi'.session.model,
            "  成员对照（@数字 即 QQ号）："
              <> T.intercalate "、" [T.pack (show u) <> "=" <> n | (u, n) <- roster]
          ]
      mentionIds = [h.messageId | h <- pi'.mention]
      ambientNoDup =
        [a | a <- pi'.ambient, a.messageId `notElem` mentionIds]
      -- Multi-chunk replies persist as several consecutive bot rows;
      -- merge them back into one assistant turn — consecutive
      -- same-role messages upset strict providers (Anthropic).
      mentionMessages = mergeAssistantRuns (map (historyToChat selfId') pi'.mention)
      userBody =
        renderUser
          selfId'
          ambientNoDup
          pi'.replyCtx
          pi'.pinnedItems
          pi'.session.btwNotes
          pi'.triggerMessage
      -- If we have inline image bytes, attach them as a multimodal
      -- content-block message, each prefixed with a label naming its
      -- source message; otherwise fall back to plain text (which
      -- still has @[image]@ markers in the body).
      --
      -- Block layout: the first label is folded into the body text
      -- and every other label sits between two images, so no two
      -- text blocks are ever adjacent — the most conservative shape
      -- for strict OpenAI-compatible providers.
      userMessage = case pi'.images of
        [] -> MsgUser userBody
        (i0 : rest) ->
          MsgUserBlocks $
            TextBlock (userBody <> "\n\n" <> i0.piLabel)
              : ImageDataUrl i0.piDataUrl
              : concat [[TextBlock i.piLabel, ImageDataUrl i.piDataUrl] | i <- rest]
      messages =
        [MsgSystem (systemPrompt pi'.multimodal (isPrivateChat pi'.triggerMessage.groupId) envText effectivePersona memBlock)]
          <> mentionMessages
          <> [userMessage]
   in (messages, pi'.session.btwNotes)

-- | The injected memory block, or 'Nothing' when there is nothing
-- remembered (no block at all beats an empty header — zero tokens,
-- and nothing for the model to fixate on).  The framing line matters
-- as much as the content: memories are 背景备忘 the model may
-- silently draw on, not a topic list to bring up.
renderMemories :: Bool -> Text -> [MemoryItem] -> [MemoryItem] -> Maybe Text
renderMemories private senderName groupMems userMems
  | null groupMems && null userMems = Nothing
  | otherwise =
      Just . T.intercalate "\n" . concat $
        [ [ "[长期记忆 — 背景备忘]",
            "这是你过去存下的备忘，仅在与当前话题直接相关时才参考。",
            "不要主动复述、评论或围绕它们展开；与当前对话矛盾时以对话为准（并考虑 memory_update）。"
          ],
          if null groupMems
            then []
            else (if private then "本会话:" else "本群:") : map memoryLine groupMems,
          if null userMems
            then []
            else ("关于当前发言者 <" <> senderName <> ">（跨群）:") : map memoryLine userMems
        ]

memoryLine :: MemoryItem -> Text
memoryLine m =
  "  (#"
    <> T.pack (show m.memId)
    <> " "
    <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d" m.memUpdatedAt)
    <> ") "
    <> oneLine m.memContent

-- | Reconstruct one bot/user turn as an OpenAI/Anthropic ChatMessage.
-- A row sent by the bot becomes 'MsgAssistant'; everything else
-- (members @-ing the bot) becomes 'MsgUser' with a sender-prefixed
-- body so the model knows who's talking when multiple members
-- address the bot.
historyToChat :: Int64 -> HistoryItem -> ChatMessage
historyToChat botId h
  | h.userId == botId = MsgAssistant h.renderedText
  | otherwise = MsgUser ("<" <> displayName botId h <> ">: " <> h.renderedText)

-- | Collapse runs of consecutive 'MsgAssistant' into one message,
-- paragraphs separated by a blank line — the inverse of the
-- chunk-splitting the reply sender does.
mergeAssistantRuns :: [ChatMessage] -> [ChatMessage]
mergeAssistantRuns = foldr step []
  where
    step (MsgAssistant a) (MsgAssistant b : rest) =
      MsgAssistant (a <> "\n\n" <> b) : rest
    step m acc = m : acc

renderUser ::
  Int64 ->
  [HistoryItem] ->
  Maybe (HistoryItem, [FileRecord], [HistoryItem]) ->
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
          Just (r, files, kids) ->
            "[引用上下文]"
              : renderReplyLine selfId' r
              : renderReplyFiles files
                <> renderReplyForward selfId' kids
                <> [""],
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
  "[" <> formatHM h.receivedAt <> " " <> displayName selfId' h <> "]: " <> oneLine h.renderedText

renderReplyLine :: Int64 -> HistoryItem -> Text
renderReplyLine selfId' h =
  "[↩ 引用 " <> formatHM h.receivedAt <> " " <> displayName selfId' h <> "]: " <> oneLine h.renderedText

-- | The expanded contents of a quoted 转发聊天记录.  Lines carry the
-- original send times; each line is truncated to keep a huge bundle
-- from eating the prompt.
renderReplyForward :: Int64 -> [HistoryItem] -> [Text]
renderReplyForward _ [] = []
renderReplyForward selfId' kids =
  ("  转发记录内容" <> capNote <> ":")
    : map (("    " <>) . T.take 200 . renderHistoryLine selfId') kids
  where
    capNote
      | length kids >= maxForwardLines = "（前 " <> T.pack (show maxForwardLines) <> " 条）"
      | otherwise = ""

-- | How many lines of a quoted forward bundle get expanded.
maxForwardLines :: Int
maxForwardLines = 30

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
  let txt = stripBotMention gm.selfId (renderPlainText gm.message)
   in "<" <> senderDisplayName gm <> ">: " <> T.strip txt

stripBotMention :: UserId -> Text -> Text
stripBotMention (UserId u) = T.replace ("@" <> T.pack (show u)) ""

-- | 群名片 > 昵称 > QQ 号 — matching what other members see on
-- screen, so the model calls people what the group calls them.
displayName :: Int64 -> HistoryItem -> Text
displayName selfId' h
  | h.userId == selfId' = "Max"
  | otherwise = fromMaybe (T.pack (show h.userId)) (bestName h)

-- | Same preference order for the live trigger message's sender.
senderDisplayName :: GroupMessage -> Text
senderDisplayName gm =
  let UserId uid = gm.userId
      Sender _ nick card = gm.sender
   in fromMaybe (T.pack (show uid)) (nonBlank card <|> nonBlank nick)
  where
    nonBlank (Just t) | not (T.null (T.strip t)) = Just (T.strip t)
    nonBlank _ = Nothing

formatHM :: UTCTime -> Text
formatHM = T.pack . formatTime defaultTimeLocale "%H:%M"

-- | Full date + Chinese weekday + time for the environment block, e.g.
-- @2026-07-13（周一） 15:42@.  Formatted off the raw 'UTCTime', same as
-- the @[HH:MM]@ context lines, so the model can line them up directly.
formatEnvTime :: UTCTime -> Text
formatEnvTime t =
  T.pack (formatTime defaultTimeLocale "%Y-%m-%d" t)
    <> "（"
    <> weekdayCN t
    <> "）"
    <> T.pack (formatTime defaultTimeLocale " %H:%M" t)

weekdayCN :: UTCTime -> Text
weekdayCN t = case formatTime defaultTimeLocale "%u" t of
  "1" -> "周一"
  "2" -> "周二"
  "3" -> "周三"
  "4" -> "周四"
  "5" -> "周五"
  "6" -> "周六"
  _ -> "周日"

oneLine :: Text -> Text
oneLine = T.replace "\n" " ⏎ "

extractReply :: [Segment] -> Maybe Int64
extractReply segs = listToMaybe [m | SegReply (MessageId m) <- segs]
