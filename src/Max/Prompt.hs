module Max.Prompt
  ( -- * Pipeline
    buildContext,

    -- * Building blocks (exposed for tests)
    PromptInputs (..),
    PromptImage (..),
    renderContext,
    contextRoster,
    applyStickerCaptions,
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
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone, UTCTime, getCurrentTime)
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
import Max.Time (fmtDate, fmtEnvStamp, fmtHM)
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
    -- | Pre-rendered 群信息 lines for the [当前环境] block (group
    -- name, 群主/管理员 — see 'Max.Roster.renderGroupBrief').  Empty
    -- for private chats or when the NapCat lookups failed.
    groupBrief :: ![Text],
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
    now :: !UTCTime,
    -- | Display timezone for every rendered timestamp ('now' and the
    -- context lines' 'receivedAt' are stored UTC; this localizes them).
    tz :: !TimeZone
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
      "  - 你在 QQ 上跟人聊天，不是在写文档；语气像真人，不像 ChatGPT 窗口里答题。",
      "  - 想说多句话时空一行分段，每段一两句话；空行隔开的段会作为独立消息逐条发出（``` 代码块不拆）。",
      "  - 禁用 markdown 排版：不要标题/粗体/斜体/列表；只有长代码或长引用才用 ``` 块。",
      "  - 表格是例外：需要对比/罗列数据时可以写 markdown 表格，它会被渲染成图片发出。",
      "  - 数学式直接写 unicode（如 3×10⁸、α ≤ π/2），不要写 LaTeX——QQ 渲染不了。",
      "  - 不寒暄、不总结收尾、不复读问题，直接说事。",
      "  - 不是每条消息都需要回：确实没什么可说的（典型如另一个 bot 机械地 @ 你——回了只会互相触发死循环，或者你只是被顺带提到）就整条回复只写 [沉默]，什么都不会发出去。正经问题不许用这个敷衍。"
    ]
      <> [ "  - 你的回复会自动引用触发消息，不必 @ 发话人；确实要提醒某人（含发话人）时写 @<QQ号>（对照表见 [当前环境]），发出时会转成真正的 @。"
         | not private
         ]
      <> [ "",
           "上下文标记：",
           "  [HH:MM <昵称>]: 内容        — 一条历史消息",
           "  [↩ 引用 ...]                — 用户引用的那条消息",
           if multimodal'
             then "  [image]                     — 图片；引用/pin/当前消息的图会附在消息末尾并标注来源"
             else "  [image]                     — 图片（你看不到内容，可以请用户描述）"
         ]
      <> [ "  [image#<id>]                — 群历史里的图片，默认不加载；跟当前话题相关时才用 view_image 传 <id> 查看"
         | multimodal'
         ]
      <> [ "  [file:<name>]               — 群文件；用 import_file_to_sandbox 处理",
           "  [forward]                   — 转发聊天记录；被引用时内容展开在 [引用上下文]",
           "  @<数字>                     — @某人；数字是 QQ 号，对照表见 [当前环境]"
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
  TimeZone -> -- display timezone for rendered timestamps
  [Text] -> -- pre-rendered 群信息 lines (see 'PromptInputs.groupBrief')
  Session ->
  GroupMessage ->
  Eff es ([ChatMessage], [Text]) -- (messages, drained btw notes)
buildContext defaultPersona n multimodal' blobRoot tz' brief s gm = do
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
  replyCtx0 <- case extractReply gm.message of
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
  -- Context stickers the caption worker has already described read
  -- as [表情包: <简介>] instead of an opaque [动画表情] marker — a
  -- non-multimodal model gets to "see" them, and a multimodal one
  -- saves image budget for real photos.
  capMap <-
    stickerCaptionsFor . map (.messageId) $
      ambient'
        <> mention'
        <> pinnedItems'
        <> maybe [] (\(r, _, kids) -> r : kids) replyCtx0
  let enrich = applyStickerCaptions capMap
      ambient'' = map enrich ambient'
      mention'' = map enrich mention'
      pinnedItems'' = map enrich pinnedItems'
      replyCtx' = fmap (\(r, f, kids) -> (enrich r, f, map enrich kids)) replyCtx0
      replyItems = maybe [] (\(r, _, kids) -> r : kids) replyCtx'
  -- Unrelated pictures in the ambient chatter are attention magnets:
  -- only images the user is plausibly pointing at (reply target, the
  -- trigger itself, pins) go inline.  Everything else keeps a text
  -- marker, upgraded with the message id ("[image#123]") so the model
  -- can pull it via the view_image tool when it actually matters.
  (ambientCtx, mentionCtx) <-
    if multimodal'
      then do
        let inlineIds =
              Set.fromList (mid : map (.messageId) (replyItems <> pinnedItems''))
            taggable =
              [ h.messageId
              | h <- ambient'' <> mention'',
                h.messageId `Set.notMember` inlineIds
              ]
        tagIds <- messagesWithImages taggable
        let tag = tagImageMarkers tagIds
        pure (map tag ambient'', map tag mention'')
      else pure (ambient'', mention'')
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
        -- pointing at, then pins (explicit user signals).  Ambient
        -- recency is deliberately NOT a candidate any more — see the
        -- marker-tagging pass above.
        loadPromptImages
          tz'
          blobRoot
          selfId'
          mid
          (Set.fromList (map (.messageId) replyItems))
          (dedupById (replyItems <> pinnedItems''))
      else pure []
  now' <- liftIO getCurrentTime
  pure $
    renderContext
      PromptInputs
        { defaultPersona = defaultPersona,
          session = s,
          triggerMessage = gm,
          ambient = ambientCtx,
          mention = mentionCtx,
          pinnedItems = pinnedItems'',
          replyCtx = replyCtx',
          multimodal = multimodal',
          groupBrief = brief,
          groupMemories = groupMems,
          userMemories = userMems,
          images = images',
          now = now',
          tz = tz'
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

-- | Everyone appearing in this turn's context, QQ号 ↔ display name.
-- Rendered text shows mentions as raw @<QQ号> (that's all the wire
-- event carries), so without this table the model cannot tell who
-- @123456 is — including itself.
contextRoster :: PromptInputs -> [(Int64, Text)]
contextRoster pi' =
  let UserId selfId' = pi'.triggerMessage.selfId
      UserId senderId = pi'.triggerMessage.userId
   in dedupeRoster $
        (selfId', "Max（你自己）")
          : (senderId, senderDisplayName pi'.triggerMessage)
          : [ (h.userId, displayName selfId' h)
            | h <-
                pi'.mention
                  <> pi'.ambient
                  <> pi'.pinnedItems
                  <> maybe [] (\(r, _, _) -> [r]) pi'.replyCtx,
              h.userId /= selfId'
            ]

-- | Keep the first (name) entry per user id.
dedupeRoster :: [(Int64, Text)] -> [(Int64, Text)]
dedupeRoster = go Set.empty
  where
    go _ [] = []
    go seen ((u, n) : rest)
      | u `Set.member` seen = go seen rest
      | otherwise = (u, n) : go (Set.insert u seen) rest

-- | Which of the given messages have at least one stored image —
-- the candidates for @[image#\<id\>]@ marker tagging.
messagesWithImages ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Set.Set Int64)
messagesWithImages [] = pure Set.empty
messagesWithImages ids = do
  rows <-
    query
      "SELECT DISTINCT message_id FROM message_images WHERE message_id IN ?"
      (Only (In ids))
  pure (Set.fromList [m | Only m <- rows])

-- | Upgrade the plain @[image]@ markers of a withheld-image message
-- to @[image#\<message_id\>]@ so the model has a handle to pass to
-- the view_image tool.  Runs after sticker-caption substitution, so
-- captioned stickers are already out of marker form.
tagImageMarkers :: Set.Set Int64 -> HistoryItem -> HistoryItem
tagImageMarkers tagged h
  | h.messageId `Set.member` tagged =
      h
        { renderedText =
            T.replace
              "[image]"
              ("[image#" <> T.pack (show h.messageId) <> "]")
              h.renderedText
        }
  | otherwise = h

-- | Captions of already-described stickers appearing in the given
-- messages, in seg_index order per message.
stickerCaptionsFor ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Map.Map Int64 [Text])
stickerCaptionsFor [] = pure Map.empty
stickerCaptionsFor ids = do
  rows <-
    query
      "SELECT mi.message_id, s.description \
      \  FROM message_images mi \
      \  JOIN stickers s USING (sha256) \
      \  WHERE mi.message_id IN ? \
      \    AND s.description IS NOT NULL AND NOT s.banned \
      \  ORDER BY mi.message_id, mi.seg_index"
      (Only (In ids))
  pure (Map.fromListWith (flip (<>)) [(m, [d]) | (m, d) <- rows :: [(Int64, Text)]])

-- | Swap sticker markers in a history item's rendered text for their
-- captions.  Markers are consumed left-to-right in seg order;
-- @[image]@ is accepted too because rows persisted before sub_type
-- survived parsing rendered stickers that way.
applyStickerCaptions :: Map.Map Int64 [Text] -> HistoryItem -> HistoryItem
applyStickerCaptions caps h = case Map.lookup h.messageId caps of
  Nothing -> h
  Just ds -> h {renderedText = replaceStickerMarkers ds h.renderedText}

replaceStickerMarkers :: [Text] -> Text -> Text
replaceStickerMarkers ds0 = go ds0
  where
    markers = ["[动画表情]", "[mface]", "[image]"] :: [Text]
    go [] rest = rest
    go (d : ds) rest = case firstMarker rest of
      Nothing -> rest
      Just (pre, post) ->
        pre <> "[表情包: " <> T.take 80 d <> "]" <> go ds post
    firstMarker rest =
      case sortOn fst [(T.length pre, m) | m <- markers, Just pre <- [findSub m rest]] of
        [] -> Nothing
        ((i, m) : _) -> Just (T.take i rest, T.drop (i + T.length m) rest)
    findSub m s = case T.breakOn m s of
      (pre, suf) | not (T.null suf) -> Just pre
      _ -> Nothing

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
  TimeZone -> -- display timezone for the image labels' HH:MM
  FilePath -> -- blob store root; images.local_path is relative to it
  Int64 -> -- bot self id (for display names in labels)
  Int64 -> -- trigger message_id
  Set.Set Int64 -> -- message ids belonging to the quoted reply (incl. forward children)
  [HistoryItem] -> -- context candidates, priority order, deduped
  Eff es [PromptImage]
loadPromptImages tz' blobRoot selfId' mid replyIds candidates = do
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
                  <> fmtHM tz' h.receivedAt
                  <> " "
                  <> displayName selfId' h
                  <> "）] 里的图片:"
            | otherwise =
                "["
                  <> fmtHM tz' h.receivedAt
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
          pi'.tz
          (isPrivateChat pi'.triggerMessage.groupId)
          senderName
          pi'.groupMemories
          pi'.userMemories
      effectivePersona = fromMaybe pi'.defaultPersona pi'.session.persona
      roster = contextRoster pi'
      envText =
        T.intercalate "\n" $
          [ "[当前环境]",
            "  现在：" <> fmtEnvStamp pi'.tz pi'.now,
            if isPrivateChat pi'.triggerMessage.groupId
              then "  场景：与 " <> senderName <> "（QQ " <> T.pack (show senderId) <> "）私聊"
              else "  群号：" <> T.pack (show gidRaw)
          ]
            <> map ("  " <>) pi'.groupBrief
            <> [ "  当前模型：" <> pi'.session.model,
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
          pi'.tz
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
renderMemories :: TimeZone -> Bool -> Text -> [MemoryItem] -> [MemoryItem] -> Maybe Text
renderMemories tz' private senderName groupMems userMems
  | null groupMems && null userMems = Nothing
  | otherwise =
      Just . T.intercalate "\n" . concat $
        [ [ "[长期记忆 — 背景备忘]",
            "仅在与当前话题相关时参考，不要主动提及；与对话矛盾时以对话为准（可 memory_update）。"
          ],
          if null groupMems
            then []
            else (if private then "本会话:" else "本群:") : map (memoryLine tz') groupMems,
          if null userMems
            then []
            else ("关于当前发言者 <" <> senderName <> ">（跨群）:") : map (memoryLine tz') userMems
        ]

memoryLine :: TimeZone -> MemoryItem -> Text
memoryLine tz' m =
  "  (#"
    <> T.pack (show m.memId)
    <> " "
    <> fmtDate tz' m.memUpdatedAt
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
  TimeZone ->
  Int64 ->
  [HistoryItem] ->
  Maybe (HistoryItem, [FileRecord], [HistoryItem]) ->
  [HistoryItem] -> -- pinned items, in user pin order
  [Text] ->
  GroupMessage ->
  Text
renderUser tz' selfId' ambient' replyCtx' pinnedItems' notes gm =
  T.intercalate "\n" $
    concat
      [ -- Pinned first so the model sees them as primary context
        if null pinnedItems'
          then []
          else
            [ "[pin 上下文 — 用户标记长期保留的消息，!clear 也不清]",
              T.intercalate "\n" (map (renderHistoryLine tz' selfId') pinnedItems'),
              ""
            ],
        ["[群最近上下文]"],
        if null ambient'
          then ["(无历史消息)"]
          else map (renderHistoryLine tz' selfId') ambient',
        [""],
        case replyCtx' of
          Nothing -> []
          Just (r, files, kids) ->
            "[引用上下文]"
              : renderReplyLine tz' selfId' r
              : renderReplyFiles files
                <> renderReplyForward tz' selfId' kids
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

renderHistoryLine :: TimeZone -> Int64 -> HistoryItem -> Text
renderHistoryLine tz' selfId' h =
  "[" <> fmtHM tz' h.receivedAt <> " " <> displayName selfId' h <> "]: " <> oneLine h.renderedText

renderReplyLine :: TimeZone -> Int64 -> HistoryItem -> Text
renderReplyLine tz' selfId' h =
  "[↩ 引用 " <> fmtHM tz' h.receivedAt <> " " <> displayName selfId' h <> "]: " <> oneLine h.renderedText

-- | The expanded contents of a quoted 转发聊天记录.  Lines carry the
-- original send times; each line is truncated to keep a huge bundle
-- from eating the prompt.
renderReplyForward :: TimeZone -> Int64 -> [HistoryItem] -> [Text]
renderReplyForward _ _ [] = []
renderReplyForward tz' selfId' kids =
  ("  转发记录内容" <> capNote <> ":")
    : map (("    " <>) . T.take 200 . renderHistoryLine tz' selfId') kids
  where
    capNote
      | length kids >= maxForwardLines = "（前 " <> T.pack (show maxForwardLines) <> " 条）"
      | otherwise = ""

-- | How many lines of a quoted forward bundle get expanded.
maxForwardLines :: Int
maxForwardLines = 30

renderReplyFiles :: [FileRecord] -> [Text]
renderReplyFiles [] = []
renderReplyFiles xs =
  "  附带文件（file_id 可直接传给 import_file_to_sandbox）:" : map fileLine xs
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


oneLine :: Text -> Text
oneLine = T.replace "\n" " ⏎ "

extractReply :: [Segment] -> Maybe Int64
extractReply segs = listToMaybe [m | SegReply (MessageId m) <- segs]
