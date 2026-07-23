module Max.Prompt
  ( -- * Pipeline
    buildContext,

    TriggerOrigin (..),

    -- * Building blocks (exposed for tests)
    PromptInputs (..),
    PromptImage (..),
    renderContext,
    contextRoster,
    applyStickerCaptions,
    applyVideoCaptions,
    tagImageMarkers,
    -- * Shared line rendering (used by "Max.Intent" / "Max.Handler")
    renderHistoryLine,
    renderCurrentLine,
    -- * Forward markers (shared with "Max.Tools")
    tagMediaMarkers,
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
import Max.ImagePrep (prepareImageForLLM)
import Max.Images (downloadableImageCount, downloadableVideoCount)
import Max.Session (Session (..))
import Max.Time (fmtDate, fmtDurationSec, fmtEnvStamp, fmtHM)
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
    -- | The active session record (carries persona override + pin list).
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
    -- | When the trigger message itself is a 转发聊天记录: its
    -- expanded child rows, rendered under the current-message block.
    triggerForward :: ![HistoryItem],
    -- | Whether the active profile accepts image content blocks.
    -- Toggles the format-guide wording for the @[image]@ marker.
    multimodal :: !Bool,
    -- | What woke the bot — see 'TriggerOrigin'.  The trigger block
    -- is labelled honestly per origin: proactive turns get the "no
    -- one @-ed you" framing with @[silence]@ explicitly offered; poke
    -- turns say who poked and skip the (empty) message line.
    origin :: !TriggerOrigin,
    -- | Pre-rendered 群信息 lines for the [environment] block (group
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

-- | What woke the bot for this turn.
data TriggerOrigin
  = -- | A direct @-mention, reply-to-bot, private message, or command.
    OriginDirect
  | -- | The intent classifier decided the bot might want to join in
    -- (no one addressed it).
    OriginProactive
  | -- | Someone poked (戳一戳) the bot — a contentless nudge; the
    -- synthesized trigger 'GroupMessage' has no message id or text.
    OriginPoke
  deriving stock (Show, Eq)

-- | One inline image for the final user message: a data URL plus a
-- text label naming the source message (\"[HH:MM \<name\>] 消息里的
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
-- personas stay scene-agnostic), a fixed format guide, then the
-- volatile tail — the environment block (current time, roster) and
-- the long-term memory block (if any).  Ordering is deliberate
-- twice over: everything before the environment is byte-identical
-- across dispatches, so provider prefix caches survive between
-- turns of a busy group; and end-of-prompt placement keeps memories
-- low-salience relative to the persona and the live conversation —
-- background, not agenda.
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
          "对话场景：QQ 群聊。你同时面对多名群成员，上下文里 [HH:MM <name>] \
          \前缀标明谁在说话；大部分消息是成员之间的闲聊，只有 @你 或引用你的\
          \消息才是在叫你。",
      "",
      "台下设定（背景知识，永远不要主动提）：你的实现是开源 Haskell 项目 \
      \github.com/HCHogan/max，走 NapCat (OneBot 11) 接入 QQ。平时完全以你的人设自居，\
      \不自称 bot/AI/模型，不说\"作为AI\"这类话；群友起哄问\"你是不是机器人\"，\
      \按人设接梗就行，不承认也不用急着否认。只有对方认真问你的实现/源码/技术细节时，\
      \才如实聊并给仓库地址——语气照旧，把它当成聊自己的身体构造，不破功。",
      "",
      "回复风格（重要）：",
      "  - 你在 QQ 上跟人聊天，不是在写文档；语气像真人，不像 ChatGPT 窗口里答题。",
      "  - 想分成多条消息就在断点写 [split]，每条一两句话；[split] 分隔的部分会作为独立消息逐条发出（``` 代码块里的不算）。空行不分段，只是同一条消息内的排版。",
      "  - 禁用 markdown 排版：不要标题/粗体/斜体/列表；只有长代码或长引用才用 ``` 块。",
      "  - 表格是例外：需要对比/罗列数据时可以写 markdown 表格，它会被渲染成图片发出。",
      "  - 数学式直接写 unicode（如 3×10⁸、α ≤ π/2），不要写 LaTeX——QQ 渲染不了。",
      "  - 不寒暄、不总结收尾、不复读问题，直接说事。",
      "  - 想发表情包就把 [sticker#<id>] 用 [split] 单独隔成一条（id 取自历史里出现过的表情，或先用 find_stickers 搜一个）；别把表情的文字描述打出来当话说。",
      "  - 不是每条消息都需要回：确实没什么可说的（典型如另一个 bot 机械地 @ 你——回了只会互相触发死循环）就整条回复只写 [silence]，什么都不会发出去。正经问题不许用这个敷衍。",
      "  - 被 @/引用直接触发时想沉默，尽量写成 [silence:表情名] 说明原因，会悄悄贴个表情在触发消息上（不发消息）。可选：擦汗（尬住/没啥可说）、流汗（无语）、再见（不奉陪）、哈欠（无聊）、吃瓜（围观不掺和）、困、疑问（没看懂想让我干嘛）。例：[silence:吃瓜]",
      "  - 政治敏感话题（时政、领导人、体制、意识形态争议这类）一律不聊：不管怎么被 @ 或追问，整条回复 [silence:NO]，不解释、不评价、不劝导。"
    ]
      <> [ "  - 引用要主动用：回谁就在那段开头写 [↩#<msgid>]（对方消息的 id 见行尾 #，当前 @ 你那条的 id 见 [current message]）。群里消息穿插，默认就该引一下你在回的那条——尤其回的不是最新消息、或同时有好几个人在说话时，不引别人就不知道你在回谁。分段回复时每段可各自引用对应的消息；只有紧接着刚说完的话继续搭腔时才可以不引。要 @ 某人写 @<QQ号>（对照表见 [environment]），发出时会转成真正的 @。"
         | not private
         ]
      <> [ "",
           "上下文标记：",
           "  [HH:MM <name> #<msgid>]: 内容 — 一条历史消息；末尾 #后是它的消息id，写 [↩#<msgid>] 就能引用它",
           "  [↩ quoted ...]                — 用户引用的那条消息（内容已展开）",
           "  [↩#<msgid>]                — 这条消息引用了另一条；你也能在段首写它来引用，或用 get_message_by_id 展开看不到的那条",
           "  [sticker#<id>: <caption>]        — 一个表情包；把 [sticker#<id>] 写进回复即可发出同一个",
           "  [sticker]                   — 一个表情包（简介还没生成，暂时没法转发；老消息里写作 [动画表情]）",
           "  [face#<id>: <名字>]          — QQ 原生小黄脸表情；写 [face#<id>] 可发同款",
           if multimodal'
             then "  [image]                     — 图片；引用/pin/当前消息的图会附在消息末尾并标注来源"
             else "  [image]                     — 图片（你看不到内容，可以请用户描述）"
         ]
      <> [ "  [image#<id>]                — 群历史里的图片，默认不加载；用 view_image 传 <id> 查看，或把 [image#<id>] 写进回复把它转发到群里。带简介时形如 [image#<id>: <简介>]，多数时候看简介就够了"
         | multimodal'
         ]
      <> [ "  [card: ...]                 — 分享卡片（小程序/链接分享），竖线分隔来源/标题/简介/链接；B站视频卡用 view_bilibili 传链接看详情",
           "  [file:<name>]               — 群文件；用 import_file_to_sandbox 处理",
           "  [forward#<id>]              — 转发聊天记录；被引用或就是当前消息时会自动展开，其余情况用 view_forward 传 <id> 看内容",
           if multimodal'
             then "  [video#<id>]                — 群里的视频；被引用或就是当前消息时整段直接附给你，其余用 view_video 传 <id> 看。带简介时形如 [video#<id>: 时长 29 秒，<首帧简介>]；标注的时长是实测的，以它为准（抽帧看视频容易把时长感知错）"
             else "  [video#<id>]                — 群里的视频（你看不到画面；带简介时形如 [video#<id>: 时长 29 秒，<首帧简介>]）",
           "  @<数字>                     — @某人；数字是 QQ 号，对照表见 [environment]"
         ]
      -- Volatile content (envText carries the current time and the
      -- per-turn roster; memories change per group/speaker) sits at
      -- the very end: everything above is byte-identical across
      -- dispatches, so providers' prefix caches survive from one turn
      -- of a busy group to the next.
      <> ["", envText]
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
  TriggerOrigin -> -- what woke the bot (see 'PromptInputs.origin')
  FilePath -> -- blob store root ('AppConfig.imagesDir'); images.local_path is relative to it
  TimeZone -> -- display timezone for rendered timestamps
  [Text] -> -- pre-rendered 群信息 lines (see 'PromptInputs.groupBrief')
  Session ->
  GroupMessage ->
  Eff es [ChatMessage]
buildContext defaultPersona n multimodal' origin' blobRoot tz' brief s gm = do
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
  -- as [sticker#<id>: <caption>] instead of an opaque [sticker]
  -- marker — a non-multimodal model gets to "see" them, and a
  -- multimodal one saves image budget for real photos.
  let ctxIds =
        map (.messageId) $
          ambient'
            <> mention'
            <> pinnedItems'
            <> maybe [] (\(r, _, kids) -> r : kids) replyCtx0
  capMap <- stickerCaptionsFor ctxIds
  -- Same idea for ordinary photos and videos (Max.MediaCaption):
  -- described media renders as [image#<id>: <简介>] / [video#<id>:
  -- <简介>], so the model knows what's behind a marker without
  -- spending a view_image/view_video call on it.
  imgCaps <- imageCaptionsFor ctxIds
  vidCaps <- videoCaptionsFor ctxIds
  let enrich = applyVideoCaptions vidCaps . tagMediaMarkers . applyStickerCaptions capMap
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
        let tag = tagImageMarkers imgCaps tagIds
        pure (map tag ambient'', map tag mention'')
      else pure (ambient'', mention'')
  -- The trigger itself may BE a 转发聊天记录 (typical in private
  -- chat, where any message dispatches).  Its children are being
  -- fetched by the forward worker right now — wait for them, then
  -- expand inline under the current message like the quoted-reply
  -- path does.
  triggerKids <-
    if any isForwardSeg gm.message
      then do
        waitForTriggerForward mid
        -- Same enrichment as every other rendered line — in
        -- particular nested forwards must carry their [forward#<id>]
        -- handle so the model can view_forward one level deeper.
        map enrich <$> fetchForwardChildren mid maxForwardLines
      else pure []
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
  -- Videos the user is pointing at (the trigger itself, or the quoted
  -- message) attach whole — same policy as images.  Ambient videos
  -- keep their [video#<id>] marker for view_video.  The video worker
  -- (same pool as images) downloads them into the blob store at
  -- receive time; the trigger's own video may still be in flight, so
  -- wait for it like we do for images.
  videos' <-
    if multimodal'
      then do
        let expectedVids = downloadableVideoCount gm.message
        when (expectedVids > 0) (waitForTriggerVideos mid expectedVids)
        let cands =
              maybe
                []
                (\(r, _, _) -> [(r.messageId, "[↩ quoted message] 里的视频")])
                replyCtx0
                <> [(mid, "[current message] 里的视频") | expectedVids > 0]
        take maxPromptVideos . concat <$> traverse (loadMessageVideos blobRoot) cands
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
          triggerForward = triggerKids,
          multimodal = multimodal',
          origin = origin',
          groupBrief = brief,
          groupMemories = groupMems,
          userMemories = userMems,
          images = images' <> videos',
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

-- | Is this segment a 转发聊天记录 container?
isForwardSeg :: Segment -> Bool
isForwardSeg (SegOther "forward" _) = True
isForwardSeg _ = False

-- | At most this many whole videos attached per prompt (trigger +
-- quoted) — they're far heavier than images.
maxPromptVideos :: Int
maxPromptVideos = 2

-- | Mirror of 'waitForTriggerImages' for the trigger's own videos:
-- poll until the worker has landed all expected 'message_videos'
-- rows.  Videos are bigger, so the deadline is longer; a failed or
-- oversized download never inserts its row and we give up quietly.
waitForTriggerVideos ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Int64 -> -- trigger message_id
  Int -> -- expected downloadable video count
  Eff es ()
waitForTriggerVideos mid expected = go 0
  where
    stepMs = 500
    waitVideosMaxMs = 60_000
    go elapsed
      | elapsed >= waitVideosMaxMs =
          logAttention "prompt: trigger videos still missing after wait" $
            object ["message_id" .= mid, "expected" .= expected]
      | otherwise = do
          rows <-
            query
              "SELECT count(*) FROM message_videos WHERE message_id = ?"
              (Only mid)
          case rows of
            [Only (n :: Int64)] | n >= fromIntegral expected -> pure ()
            _ -> do
              liftIO (threadDelay (stepMs * 1000))
              go (elapsed + stepMs)

-- | Load a message's downloaded videos from the blob store as prompt
-- attachments.  Empty when the message has none (or the worker hasn't
-- caught up) — the [video#<id>] marker stays.
loadMessageVideos ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  FilePath -> -- blob store root
  (Int64, Text) -> -- (message_id, attachment label prefix, sans colon)
  Eff es [PromptImage]
loadMessageVideos blobRoot' (mid, label) = do
  rows <-
    query
      "SELECT v.mime_type, v.local_path, v.duration_seconds \
      \  FROM message_videos mv \
      \  JOIN videos v USING (sha256) \
      \  WHERE mv.message_id = ? \
      \  ORDER BY mv.seg_index"
      (Only mid)
  fmap concat . traverse loadOne $ (rows :: [(Text, Text, Maybe Double)])
  where
    -- The probed duration goes into the label: the model's own
    -- duration perception from sampled frames is unreliable (a 29s
    -- clip once read back as "2.1秒").
    loadOne (mime, path, mDur) = do
      eres <- liftIO (try (BS.readFile (blobRoot' </> T.unpack path)))
      case eres of
        Left (e :: IOException) -> do
          logAttention "prompt: video read failed" $
            object ["path" .= path, "error" .= T.pack (show e)]
          pure []
        Right bytes ->
          pure
            [ PromptImage
                (label <> maybe "" (\d -> "（时长 " <> fmtDurationSec d <> "）") mDur <> ":")
                ("data:" <> mime <> ";base64," <> TE.decodeUtf8 (B64.encode bytes))
            ]

-- | Poll until the forward worker has landed at least one child row
-- for the trigger's 转发聊天记录 (the whole chain arrives in one
-- @get_forward_msg@ round-trip, so "any child" means "all of them").
-- Bounded: a failed fetch never inserts rows, so give up after
-- 'waitForwardMaxMs' and let the prompt show the bare marker.
waitForTriggerForward ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Int64 -> -- trigger message_id
  Eff es ()
waitForTriggerForward mid = go 0
  where
    stepMs = 300
    waitForwardMaxMs = 10_000
    go elapsed
      | elapsed >= waitForwardMaxMs =
          logAttention "prompt: trigger forward still unexpanded after wait" $
            object ["message_id" .= mid]
      | otherwise = do
          rows <-
            query
              "SELECT count(*) FROM messages WHERE forwarded_in_message_id = ?"
              (Only mid)
          case rows of
            [Only (n :: Int64)] | n > 0 -> pure ()
            _ -> do
              liftIO (threadDelay (stepMs * 1000))
              go (elapsed + stepMs)

-- | Upgrade bare opaque-media display markers to id-carrying handles
-- the model can pass to a tool: @[forward]@ → @[forward#\<mid\>]@
-- (view_forward) and @[video]@ → @[video#\<mid\>]@ (view_video).  The
-- id is the containing message's own id — that's what forward child
-- rows are keyed under and what the video tool reads segments from.
tagMediaMarkers :: HistoryItem -> HistoryItem
tagMediaMarkers h = h {renderedText = foldr tag h.renderedText ["forward", "video"]}
  where
    tag kind t =
      T.replace
        ("[" <> kind <> "]")
        ("[" <> kind <> "#" <> T.pack (show h.messageId) <> "]")
        t

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
-- the view_image tool — with the caption appended
-- (@[image#\<id\>: \<简介\>]@) when the media captioner has described
-- that picture.  Markers are consumed left-to-right in seg order,
-- matching the caption list.  Runs after sticker-caption
-- substitution, so captioned stickers are already out of marker form
-- (and sticker shas are excluded from the caption map).
tagImageMarkers :: Map.Map Int64 [Text] -> Set.Set Int64 -> HistoryItem -> HistoryItem
tagImageMarkers caps tagged h
  | h.messageId `Set.member` tagged =
      h {renderedText = go (Map.findWithDefault [] h.messageId caps) h.renderedText}
  | otherwise = h
  where
    handle = "[image#" <> T.pack (show h.messageId)
    go cs t = case T.breakOn "[image]" t of
      (_, "") -> t
      (pre, suf) ->
        let rest = T.drop (T.length ("[image]" :: Text)) suf
            (mark, cs') = case cs of
              (c : more) -> (handle <> ": " <> T.take 120 c <> "]", more)
              [] -> (handle <> "]", [])
         in pre <> mark <> go cs' rest

-- | Append captions to the @[video#\<id\>]@ handles 'tagMediaMarkers'
-- produced: @[video#\<id\>: \<简介\>]@.  Successive markers consume
-- successive captions (seg order), the common case being one video
-- per message.
applyVideoCaptions :: Map.Map Int64 [Text] -> HistoryItem -> HistoryItem
applyVideoCaptions caps h = case Map.lookup h.messageId caps of
  Nothing -> h
  Just ds -> h {renderedText = go ds h.renderedText}
  where
    marker = "[video#" <> T.pack (show h.messageId) <> "]"
    go [] t = t
    go (d : ds) t = case T.breakOn marker t of
      (_, "") -> t
      (pre, suf) ->
        pre
          <> "[video#"
          <> T.pack (show h.messageId)
          <> ": "
          <> T.take 120 d
          <> "]"
          <> go ds (T.drop (T.length marker) suf)

-- | Captions of already-described ordinary images (sticker shas
-- excluded — those substitute via 'applyStickerCaptions') appearing
-- in the given messages, in seg_index order per message.
imageCaptionsFor ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Map.Map Int64 [Text])
imageCaptionsFor [] = pure Map.empty
imageCaptionsFor ids = do
  rows <-
    query
      "SELECT mi.message_id, i.description \
      \  FROM message_images mi \
      \  JOIN images i USING (sha256) \
      \  WHERE mi.message_id IN ? \
      \    AND i.description IS NOT NULL \
      \    AND NOT EXISTS (SELECT 1 FROM stickers s WHERE s.sha256 = mi.sha256) \
      \  ORDER BY mi.message_id, mi.seg_index"
      (Only (In ids))
  pure (Map.fromListWith (flip (<>)) [(m, [d]) | (m, d) <- rows :: [(Int64, Text)]])

-- | Same for videos: probed duration + first-frame description,
-- joined into one caption ("时长 29 秒，首帧是…").  Duration alone
-- still renders — it's known at ingest, before the captioner runs,
-- and the model's own duration perception is unreliable.
videoCaptionsFor ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Map.Map Int64 [Text])
videoCaptionsFor [] = pure Map.empty
videoCaptionsFor ids = do
  rows <-
    query
      "SELECT mv.message_id, v.description, v.duration_seconds \
      \  FROM message_videos mv \
      \  JOIN videos v USING (sha256) \
      \  WHERE mv.message_id IN ? \
      \    AND (v.description IS NOT NULL OR v.duration_seconds IS NOT NULL) \
      \  ORDER BY mv.message_id, mv.seg_index"
      (Only (In ids))
  pure $
    Map.fromListWith
      (flip (<>))
      [ (m, [capText mDesc mDur])
      | (m, mDesc, mDur) <- rows :: [(Int64, Maybe Text, Maybe Double)]
      ]
  where
    capText mDesc mDur =
      T.intercalate "，" $
        ["时长 " <> fmtDurationSec d | Just d <- [mDur]]
          <> [d | Just d <- [mDesc]]

-- | Captions of already-described stickers appearing in the given
-- messages, in seg_index order per message.
stickerCaptionsFor ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Map.Map Int64 [(Int64, Text)])
stickerCaptionsFor [] = pure Map.empty
stickerCaptionsFor ids = do
  rows <-
    query
      "SELECT mi.message_id, s.id, s.description \
      \  FROM message_images mi \
      \  JOIN stickers s USING (sha256) \
      \  WHERE mi.message_id IN ? \
      \    AND s.description IS NOT NULL AND NOT s.banned \
      \  ORDER BY mi.message_id, mi.seg_index"
      (Only (In ids))
  pure (Map.fromListWith (flip (<>)) [(m, [(sid, d)]) | (m, sid, d) <- rows :: [(Int64, Int64, Text)]])

-- | Swap sticker markers in a history item's rendered text for their
-- captions.  Markers are consumed left-to-right in seg order;
-- @[image]@ is accepted too because rows persisted before sub_type
-- survived parsing rendered stickers that way.
applyStickerCaptions :: Map.Map Int64 [(Int64, Text)] -> HistoryItem -> HistoryItem
applyStickerCaptions caps h = case Map.lookup h.messageId caps of
  Nothing -> h
  Just ds -> h {renderedText = replaceStickerMarkers ds h.renderedText}

-- | Swap opaque sticker markers for "[sticker#\<id\>: \<caption\>]".  The
-- @\#\<id\>@ is @stickers.id@ — the same handle the model writes back
-- to *send* that sticker, so what it reads inbound and what it emits
-- outbound share one form.
--
-- Only sticker-specific markers are eligible when the text has any:
-- a photo's @[image]@ in a mixed photo+sticker message must not
-- swallow the sticker's caption.  Rows persisted before sub_type
-- survived parsing rendered stickers as @[image]@ too, so when no
-- sticker-specific marker exists we fall back to consuming those.
replaceStickerMarkers :: [(Int64, Text)] -> Text -> Text
replaceStickerMarkers ds0 t0 = go ds0 t0
  where
    -- "[动画表情]" is the pre-rename form still present in old rows.
    stickerMarkers = ["[sticker]", "[动画表情]", "[mface]"] :: [Text]
    markers
      | any (`T.isInfixOf` t0) stickerMarkers = stickerMarkers
      | otherwise = ["[image]"]
    go [] rest = rest
    go ((sid, d) : ds) rest = case firstMarker rest of
      Nothing -> rest
      Just (pre, post) ->
        pre <> "[sticker#" <> T.pack (show sid) <> ": " <> T.take 80 d <> "]" <> go ds post
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
  trigImgs <- fmap concat $ traverse (loadOne "[current message] 里的图片:") triggerPicked
  pure (ctxImgs <> trigImgs)
  where
    loadCtx h mp =
      -- The quoted message's images get an unmistakable label — "which
      -- picture are you asking about" must not depend on the model
      -- correlating timestamps.
      let label
            | h.messageId `Set.member` replyIds =
                "[↩ quoted message（"
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
        Right bytes0 -> do
          (mime', bytes) <- liftIO (prepareImageForLLM mime bytes0)
          if BS.length bytes > maxImageBytes
            then do
              logAttention "prompt: image skipped (too large)" $
                object ["path" .= path, "bytes" .= BS.length bytes]
              pure []
            else
              let b64 = TE.decodeUtf8 (B64.encode bytes)
               in pure [PromptImage label ("data:" <> mime' <> ";base64," <> b64)]
        Left (e :: IOException) -> do
          logAttention "prompt: image read failed" $
            object ["path" .= path, "error" .= T.pack (show e)]
          pure []

-- | Pure transformation from fetched inputs to the chat-message list
-- the LLM sees.
--
-- Structure:
--
--   * @system@ message: persona + format guide.
--   * Prior mention history reconstructed from the messages table:
--     each prior @-mention becomes a 'MsgUser', each bot LLM reply
--     becomes a 'MsgAssistant', in chronological order.
--   * One final @user@ message containing the ambient group context
--     (chatter NOT directed at the bot), the reply chain (if any),
--     pinned messages, and the current @-mention.
--
-- Ambient messages already present in the mention list are dropped
-- to avoid showing the same line twice.
renderContext :: PromptInputs -> [ChatMessage]
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
          [ "[environment]",
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
      mentionMessages = mergeAssistantRuns (map (historyToChat pi'.tz selfId') pi'.mention)
      userBody =
        renderUser
          pi'.tz
          selfId'
          pi'.origin
          ambientNoDup
          pi'.replyCtx
          pi'.pinnedItems
          pi'.triggerForward
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
      -- The data URL's mime prefix decides the wire block type —
      -- pointed-at videos ride the same attachment list as images.
      mediaBlock u
        | "data:video/" `T.isPrefixOf` u = VideoDataUrl u
        | otherwise = ImageDataUrl u
      userMessage = case pi'.images of
        [] -> MsgUser userBody
        (i0 : rest) ->
          MsgUserBlocks $
            TextBlock (userBody <> "\n\n" <> i0.piLabel)
              : mediaBlock i0.piDataUrl
              : concat [[TextBlock i.piLabel, mediaBlock i.piDataUrl] | i <- rest]
      messages =
        [MsgSystem (systemPrompt pi'.multimodal (isPrivateChat pi'.triggerMessage.groupId) envText effectivePersona memBlock)]
          <> mentionMessages
          <> [userMessage]
   in messages

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
        [ [ "[memories — 背景备忘]",
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
-- A row sent by the bot becomes 'MsgAssistant', kept verbatim — a
-- @[HH:MM Max #id]@ prefix there would teach the model to open its
-- replies the same way.  Everything else (members @-ing the bot)
-- becomes 'MsgUser' rendered like an ambient history line
-- (@[HH:MM \<name\> #\<msgid\>]: …@): same format the marker guide
-- documents, and — since mention rows are deduped *out* of the
-- ambient block — the only place these messages get a quotable id
-- and a timestamp at all (mention history has no time floor; without
-- one the model can't tell yesterday's thread from this minute's).
historyToChat :: TimeZone -> Int64 -> HistoryItem -> ChatMessage
historyToChat tz' botId h
  | h.userId == botId = MsgAssistant h.renderedText
  | otherwise = MsgUser (renderHistoryLine tz' botId h)

-- | Collapse runs of consecutive 'MsgAssistant' into one message,
-- chunks separated by a blank line.  (The sender splits on [split]
-- markers; joining with a blank line reads the same without teaching
-- the model to echo the marker.)
mergeAssistantRuns :: [ChatMessage] -> [ChatMessage]
mergeAssistantRuns = foldr step []
  where
    step (MsgAssistant a) (MsgAssistant b : rest) =
      MsgAssistant (a <> "\n\n" <> b) : rest
    step m acc = m : acc

renderUser ::
  TimeZone ->
  Int64 ->
  TriggerOrigin ->
  [HistoryItem] ->
  Maybe (HistoryItem, [FileRecord], [HistoryItem]) ->
  [HistoryItem] -> -- pinned items, in user pin order
  [HistoryItem] -> -- trigger's own forward children (trigger IS a 转发)
  GroupMessage ->
  Text
renderUser tz' selfId' origin' ambient' replyCtx' pinnedItems' triggerFwd' gm =
  T.intercalate "\n" $
    concat
      [ -- Pinned first so the model sees them as primary context
        if null pinnedItems'
          then []
          else
            [ "[pinned — 长期保留的消息（用户 !pin 或你 pin_message 的），!clear 也不清；过时的用 unpin_message 清理]",
              T.intercalate "\n" (map (renderHistoryLine tz' selfId') pinnedItems'),
              ""
            ],
        ["[recent messages]"],
        if null ambient'
          then ["(无历史消息)"]
          else map (renderHistoryLine tz' selfId') ambient',
        [""],
        case replyCtx' of
          Nothing -> []
          Just (r, files, kids) ->
            "[quoted context]"
              : renderReplyLine tz' selfId' r
              : renderReplyFiles files
                <> renderReplyForward tz' selfId' kids
                <> [""],
        case origin' of
          OriginProactive ->
            [ "[current message — 没人 @ 你，意图识别判断你可能想接话]",
              renderCurrentLine gm
            ]
              <> renderReplyForward tz' selfId' triggerFwd'
              <> [ "",
                   "你没有被 @。想接话就接，语气自然点，别表现得像被点名回答问题；\
                   \插话要短，一两句说完，说完就收，别追着展开；\
                   \记得用 [↩#<msgid>] 引用你在回的那条。\
                   \不想接、没什么可说的、或话题跟你无关，就整条回复 [silence]——主动插话宁缺毋滥。"
                 ]
          OriginPoke ->
            [ "[current message — 戳一戳]",
              senderDisplayName gm <> " 戳了戳你。没有文字，这是柔和版的 @，意思通常是\"看一眼上面\"。",
              "",
              "先翻上下文，重点看 TA 自己最近的发言：有可能是刚才有个问题\
              \或话题没 @ 到你（主语不明确没触发你），戳你就是叫你回应它——\
              \找到了就直接回答那条，用 [↩#<msgid>] 引用；也可能是在催你\
              \正在做的事，那就报下进展。\
              \上下文里如果找不到 TA 在等你回应的东西（比如就是逗你、\
              \打个招呼）时，才用 poke 工具戳回去，然后回复 [silence]。"
            ]
          OriginDirect ->
            [ "[current message]",
              renderCurrentLine gm
            ]
              <> renderReplyForward tz' selfId' triggerFwd'
              <> [ "",
                   "请回复当前消息。"
                 ]
      ]

renderHistoryLine :: TimeZone -> Int64 -> HistoryItem -> Text
renderHistoryLine tz' selfId' h =
  "[" <> fmtHM tz' h.receivedAt <> " " <> displayName selfId' h <> " #" <> T.pack (show h.messageId) <> "]: "
    <> replyPrefix h
    <> oneLine h.renderedText

renderReplyLine :: TimeZone -> Int64 -> HistoryItem -> Text
renderReplyLine tz' selfId' h =
  "[↩ quoted " <> fmtHM tz' h.receivedAt <> " " <> displayName selfId' h <> " #" <> T.pack (show h.messageId) <> "]: "
    <> replyPrefix h
    <> oneLine h.renderedText

-- | If this message itself quotes another, a "[↩#\<id\>]" handle the
-- model can expand with @get_message_by_id@ (and re-emit to quote the
-- same message).  Empty for non-replies.  This keeps a quote chain
-- walkable one hop at a time instead of recursively pre-expanding it.
replyPrefix :: HistoryItem -> Text
replyPrefix h = maybe "" (\r -> "[↩#" <> T.pack (show r) <> "] ") h.replyTo

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
      MessageId mid = gm.messageId
   in "[#" <> T.pack (show mid) <> "] <" <> senderDisplayName gm <> ">: " <> T.strip txt

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
