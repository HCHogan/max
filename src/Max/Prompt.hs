module Max.Prompt
  ( -- * Pipeline
    buildContext,
    buildContextWithLimits,
    buildContextWithReadMode,
    ContextReadMode (..),
    TriggerOrigin (..),

    -- * Building blocks (exposed for tests)
    PromptInputs (..),
    PromptImage (..),
    ContextCompartment (..),
    CompartmentTier (..),
    ContextSnapshot (..),
    ContextPlan (..),
    collectContext,
    planContext,
    applyBaseCompartmentTiers,
    renderContextPlan,
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
import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Either (partitionEithers)
import Data.Function (on)
import Data.Int (Int64)
import Data.List (find, groupBy, minimumBy, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone, UTCTime, diffUTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (In (..), Only (..))
import Effectful
import Effectful.Exception (IOException, try)
import Effectful.Log (Log, logAttention, logInfo, object, (.=))
import Effectful.PostgreSQL (WithConnection, query)
import Max.Context
  ( ContextBudget (..),
    ContextDecision (..),
    ContextTrace (..),
    contextBudget,
    estimateMessagesTokens,
    estimateTextTokens,
  )
import Max.ContextMaterialization
  ( ContextMaterialization (..),
    MaterializationDraft (..),
    MaterializedCompartment (..),
    loadContextMaterialization,
    publishContextMaterialization,
  )
import Max.ContextTraceStore (recordContextPlanTrace)
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.Files (FileRecord (..))
import Max.DB.Files qualified as DBFiles
import Max.DB.History
  ( HistoryItem (..),
    HistoryPage (..),
    LedgerItem (..),
    MessageCursor (..),
    bestName,
    fetchForwardChildrenInScope,
    fetchMessageInScope,
    fetchMessagesByIdsInScope,
    fetchNewestPromptPageBefore,
  )
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.Effects.LLM (ChatMessage (..), ContentBlock (..))
import Max.EpisodeStore (ActiveCompartment (..), CompartmentId (..), EpisodeHandle, SourceRange (..), episodeHandleText, listActiveCompartments)
import Max.Faces (curatedFaceGroups)
import Max.ImagePrep (prepareImageForLLM)
import Max.Images (downloadableImageCount, downloadableVideoCount)
import Max.MemoryStore (MemoryId (..), MemoryItem (..), MemoryVersion (..), groupMemoryNamespace, listRecentMemories, userMemoryNamespace)
import Max.ModelCatalog (ContextLimits, defaultContextLimits)
import Max.Session (Session (..))
import Max.Time (fmtDate, fmtDurationSec, fmtEnvStamp, fmtHM)
import Max.Util (trySync)
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)

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
    -- | One chronological transcript of the conversation: ambient
    -- group chatter and the bot's own thread with people, interleaved
    -- and deduped by message id.
    --
    -- One list rather than two, and plain text rather than
    -- @user@\/@assistant@ turns, because a group has N speakers and
    -- neither wire format can say so — @user@ conflates everybody, and
    -- @assistant@ drops who the bot was talking to.  A line that names
    -- its speaker, its time and its id carries strictly more than the
    -- roles did, and every model reads it, because it is just text.
    -- (The Chat Completions @name@ field exists for exactly this and is
    -- the wrong bet: the Responses API dropped it outright, Anthropic
    -- never had it, and it has no documented validation, so what an
    -- OpenAI-compatible provider does with it is anyone's guess.)
    transcript :: ![HistoryItem],
    -- | Settled chronological history preceding 'transcript'.  Each item
    -- carries all precomputed fidelity levels; ContextPolicy chooses one
    -- without invoking an LLM.  Empty in legacy mode.
    compartments :: ![ContextCompartment],
    -- | Put history back into real @user@\/@assistant@ turns instead of
    -- the flat transcript.  Per-profile
    -- ('Max.ModelCatalog.usesHistoryTurns') so the two shapes can be
    -- compared on the live bot rather than argued about; see that
    -- field for the trade.
    historyTurns :: !Bool,
    -- | Message ids in 'transcript' that another dispatch is answering
    -- right now.  Their replies aren't in the messages table yet, so
    -- they would render as questions the bot still owes an answer to
    -- and the model helpfully answers them alongside ours — the group
    -- then gets the same question answered twice.  Dropped from the
    -- prompt outright: the model can't double-answer what it can't
    -- see, and unlike an explanatory annotation, an absent line is
    -- nothing for the model to mistake for something it should say.
    -- (That is not hypothetical — the annotation this replaced got
    -- emitted verbatim as a reply.)
    inFlight :: !(Set Int64),
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
    -- | Long-term memories of the *triggering* user, confined to the
    -- ones learned in this group, oldest first.  Other members'
    -- memories are not injected — the model can @memory_list@ them
    -- when actually relevant.
    userMemories :: ![MemoryItem],
    -- | Already-loaded images to attach to the final user message,
    -- in display order (context images chronological, trigger's
    -- last).  Populated only when 'multimodal' AND the image worker
    -- has finished fetching; otherwise empty and images remain as
    -- @[image]@ markers in the rendered text.
    images :: ![PromptImage],
    -- | Skill index for this group: (name, one-line description)
    -- pairs, global + group-scoped merged, name-sorted (see
    -- 'Max.Skills.skillsForGroup').  Rendered into the system prompt's
    -- 技能对照表; empty = no section, and no @use_skill@ tool either.
    -- Pairs rather than the full skill record so rendering stays a
    -- pure function of small fixture-friendly inputs.
    skills :: ![(Text, Text)],
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

-- | Process-wide release reader choice.  The emergency mode is deliberately
-- raw-only rather than a resurrection of the retired mention/history lane.
data ContextReadMode
  = TieredContext
  | RawLedgerEmergency
  deriving stock (Show, Eq)

data CompartmentTier = TierP1 | TierP2 | TierP3 | TierP4
  deriving stock (Show, Eq, Ord, Enum, Bounded)

-- | Pure prompt-facing form of an immutable active compartment.  Keeping all
-- three summaries in the snapshot makes fidelity selection deterministic and
-- rebuild-free inside ContextPolicy.
data ContextCompartment = ContextCompartment
  { contextCompartmentId :: !Int64,
    contextExpandHandle :: !EpisodeHandle,
    contextStartedAt :: !UTCTime,
    contextEndedAt :: !UTCTime,
    contextImportance :: !Double,
    contextConfidence :: !Double,
    contextMaterializationVersion :: !Int64,
    contextSummaryP1 :: !Text,
    contextSummaryP2 :: !Text,
    contextSummaryP3 :: !Text,
    contextTier :: !CompartmentTier
  }
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

-- | Complete output of the effectful collection step, before any pure prompt
-- selection.  Token safety is owned entirely by 'planContext'.
data ContextSnapshot = ContextSnapshot
  { csInputs :: !PromptInputs,
    csMaterializationVersion :: !(Maybe Int64),
    csMaterializationReason :: !(Maybe Text)
  }

-- | Deterministic, fully selected context with its budget and decision trace.
-- Rendering this value performs no I/O and no further selection.
data ContextPlan = ContextPlan
  { cpInputs :: !PromptInputs,
    cpBudget :: !ContextBudget,
    cpEstimatedPromptTokens :: !Int,
    cpWithinBudget :: !Bool,
    cpTrace :: ![ContextTrace],
    cpPolicyVersion :: !Text,
    cpMaterializationVersion :: !(Maybe Int64),
    cpMaterializationReason :: !(Maybe Text)
  }

data HistoryTokenWatermarks = HistoryTokenWatermarks
  { htwLow :: !Int,
    htwHigh :: !Int
  }

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
  Text -> -- persona
  [(Text, Text)] -> -- skill index: (name, description), name-sorted
  Text
systemPrompt multimodal' private persona skills' =
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
      \才如实聊并给仓库地址——语气照旧，把它当成聊自己的身体构造，不破功。\
      \认真聊实现/部署/命令用法之前，先用 use_skill 取 self-knowledge 对着说，别凭印象编。",
      "",
      "回复风格（重要）：",
      "  - 你在 QQ 上跟人聊天，不是在写文档；语气像真人，不像 ChatGPT 窗口里答题。",
      "  - 想说多句话时空一行分段，每段一两句话；空行隔开的段会作为独立消息逐条发出（``` 代码块不拆）；行内要切可用 [split]。",
      "  - 禁用 markdown 排版：不要标题/粗体/斜体/列表；只有长代码或长引用才用 ``` 块。",
      "  - 表格是例外：需要对比/罗列数据时可以写 markdown 表格，它会被渲染成图片发出。",
      "  - 数学式直接写 unicode（如 3×10⁸、α ≤ π/2），不要写 LaTeX——QQ 渲染不了。",
      "  - 不寒暄、不总结收尾、不复读问题，直接说事。",
      "  - 要调工具时，把「你打算干嘛」和工具调用写在同一条回复里——正文一句短话，工具调用照发，两者可以同时输出。用户看不见你调了什么，只看得见你卡在那儿不说话。开工、关键步骤成败、改主意时各一句；连着好几轮工具没吭声也该报一下。最终答案等工具跑完再正常写，别在播报里提前答。",
      "  - 表情用得克制：默认不发，文字说清就够了，不必再配表情包/小黄脸；只有它确实比一句话更到位时才发，一条回复最多一个。（贴在别人消息上的 [silence:表情名] 不算，该用还是用。）",
      "  - 真要发表情包就把 [sticker#<id>] 单独写成一段（id 取自历史里出现过的表情，或先用 find_stickers 工具搜一个）；别把表情的文字描述打出来当话说。",
      "  - 不是每条消息都需要回：确实没什么可说的（典型如另一个 bot 机械地 @ 你——回了只会互相触发死循环）就整条回复只写 [silence]，什么都不会发出去。正经问题不许用这个敷衍。",
      "  - 被 @/引用直接触发时沉默不会完全无声：[silence] 会自动在触发消息上贴一个闭嘴表情（不发消息）。想表达具体情绪可换 [silence:表情名]，名字从小黄脸对照表（见下）挑，如 [silence:吃瓜]。",
      "  - 政治敏感话题（时政、领导人、体制、意识形态争议这类）一律不聊：不管怎么被 @ 或追问，整条回复 [silence:NO]，不解释、不评价、不劝导。"
    ]
      <> [ "  - 引用要主动用：回谁就在那段开头写 [↩#<msgid>]（对方消息的 id 见行首 #，当前 @ 你那条的 id 见 [current message]）。群里消息穿插，默认就该引一下你在回的那条——尤其回的不是最新消息、或同时有好几个人在说话时，不引别人就不知道你在回谁。分段回复时每段可各自引用对应的消息；只有紧接着刚说完的话继续搭腔时才可以不引。要 @ 某人写 [@#<QQ号>]（对照表见 [environment]），发出时会转成真正的 @。"
         | not private
         ]
      <> [ "",
           "占位符语法（整个体系只有一条构词律）：",
           "  [类型#id: 描述](属性)   —— 描述、(属性) 都是可选的补充，只给你看；id 是数字",
           "  想发同款/执行动作，只写 [类型#id]，描述和 (属性) 都不要抄（抄了也只认 id）。",
           "",
           "你能读到的实体：",
           "  [sticker#42: 柴犬瘫地]       — 表情包（简介还没生成的显示为 [sticker]，老消息里写作 [动画表情]，暂时没法转发）",
           "  [face#14: 惊讶]             — QQ 原生小黄脸表情",
           if multimodal'
             then "  [image#7405: 简介]          — 群历史里的图片，默认不加载；多数时候看简介就够，要看原图用 view_image 传 id。当前消息/引用/pin 的图直接附在消息末尾（正文里显示 [image]）"
             else "  [image#7405: 简介] / [image] — 图片（你看不到原图，看简介或请用户描述）",
           if multimodal'
             then "  [video#7407: 首帧简介](29秒) — 群里的视频；(29秒) 是实测时长，以它为准（抽帧看视频容易把时长感知错）。被引用或就是当前消息时整段附给你，其余用 view_video 传 id 看"
             else "  [video#7407: 首帧简介](29秒) — 视频（你看不到画面；时长是实测的）",
           "  [forward#7519]              — 转发聊天记录；被引用或就是当前消息时自动展开，其余用 view_forward 传 id 看",
           "  [@#223344556: 名字]          — @某人；对照表见 [environment]",
           "",
           "你能写的动作（只有这 8 个，全部在此）：",
           "  [split]  行内强制分条（一般用空行分段就行）     [↩#id]  段首引用     [@#QQ号]  @某人（直接写 @名字 只是普通文字，对方收不到提醒——必须用 [@#QQ号]，号码查 [environment] 对照表）",
           "  [sticker#id]  发表情包     [face#id]  发小黄脸     [image#id]  把群里的图转发出来",
           "  [silence]  沉默（直接触发自动贴闭嘴表情）     [silence:表情名]  沉默并贴指定表情",
           "",
           "小黄脸对照表（条目格式 名字#id：[face#id] 发消息用 id，[silence:表情名] 贴表情用名字，都只认这张表）："
         ]
      <> [ "  " <> label <> "：" <> T.unwords [name <> "#" <> T.pack (show fid) | (name, fid) <- faces]
         | (label, faces) <- curatedFaceGroups
         ]
      <> [ "",
           "纯展示（只读，写了也不会发生任何事）：",
           "  行首 [HH:MM <name> #<msgid>]: — 历史消息行；#后是消息 id，引用它就写 [↩#那个id]。\
           \你自己以前说的话也在这份记录里，名字是 Max——那是记录格式，不是说话方式：\
           \你的回复正文直接写内容，绝对不要带这个行首前缀。",
           "  [episode#<uuid> 日期..日期 P1/P2/P3] — 更早聊天的可重建摘要；需要原话时把 uuid 传给 context_expand。",
           "  [↩ quoted ...]               — 用户引用的那条消息（内容已展开；也可用 get_message_by_id 展开任意 id）",
           "  [card: 来源 | 标题 | 链接]     — 分享卡片；B站卡用 view_bilibili、知乎卡用 view_zhihu，传链接看内容",
           "  [file:<name>]                — 群文件；用 import_file_to_sandbox 处理",
           "",
           "铁律：动作只有上面那 8 个。工具调用永远走工具通道，把工具名写进方括号",
           "（如 [find_stickers query=...]）不会执行任何东西，也不会发出去。",
           "",
           "示范——一条带引用、@、分段、表情包的回复该长这样（id 都要取自上下文，",
           "别照抄示范里的数字；表情包只写数字 id、单独成段）：",
           "  [↩#7413] 这是 HardFault，PC 指到 0x08003a2c，查一下链接脚本。",
           "  [split]",
           "  [↩#7405] [@#223344556] 你那个是探头打了 1X，切 10X 再看。",
           "  [split]",
           "  [sticker#3407]"
         ]
      -- The skill index: one line per skill, name-sorted upstream, so
      -- the section is byte-identical across dispatches until someone
      -- edits a skill.  The body lives behind the use_skill tool —
      -- progressive disclosure keeps a 20-skill group from paying 20
      -- bodies per dispatch.
      <> ( if null skills'
             then []
             else
               [ "",
                 "技能对照表（预先写好的做事流程；条目只有一句简介，用 use_skill 传名字\
                 \取完整说明再照着做。只在简介和手头的事明确对上时取用，日常聊天用不到）："
               ]
                 <> ["  " <> n <> "：" <> d | (n, d) <- skills']
         )

-- Nothing volatile below this point.  The environment block
-- (current time, per-turn roster) and the memory block used to
-- sit here at the end; they now live in the user message, after
-- the transcript.  A prefix cache stops at the first byte that
-- changed, so a clock in the system prompt capped every provider
-- cache at "persona + format guide" no matter how stable the
-- conversation below it was.

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
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- default persona (used when session has no override)
  Bool -> -- multimodal: load + attach inline images
  Bool -> -- history as user/assistant turns (see 'PromptInputs.historyTurns')
  TriggerOrigin -> -- what woke the bot (see 'PromptInputs.origin')
  TimeZone -> -- display timezone for rendered timestamps
  [Text] -> -- pre-rendered 群信息 lines (see 'PromptInputs.groupBrief')
  [(Text, Text)] -> -- skill index for this group (see 'PromptInputs.skills')
  Set Int64 -> -- triggers another turn is already answering (see 'PromptInputs.inFlight')
  Session ->
  GroupMessage ->
  Eff es [ChatMessage]
buildContext = buildContextWithLimits defaultContextLimits

-- | Production entry point with limits taken from the selected model profile.
buildContextWithLimits ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ContextLimits ->
  Text ->
  Bool ->
  Bool ->
  TriggerOrigin ->
  TimeZone ->
  [Text] ->
  [(Text, Text)] ->
  Set Int64 ->
  Session ->
  GroupMessage ->
  Eff es [ChatMessage]
buildContextWithLimits limits = buildContextWithReadMode limits TieredContext

buildContextWithReadMode ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ContextLimits ->
  ContextReadMode ->
  Text ->
  Bool ->
  Bool ->
  TriggerOrigin ->
  TimeZone ->
  [Text] ->
  [(Text, Text)] ->
  Set Int64 ->
  Session ->
  GroupMessage ->
  Eff es [ChatMessage]
buildContextWithReadMode limits readMode defaultPersona multimodal' historyTurns' origin' tz' brief skills' inFlight' s gm = do
  let promptLimit = (contextBudget limits multimodal').cbPromptTokenLimit
      historyWatermarks =
        HistoryTokenWatermarks
          { htwLow = max 512 (promptLimit `div` 5),
            htwHigh = max 1024 (promptLimit * 2 `div` 5)
          }
  snapshot <-
    collectContextWithWatermarks
      readMode
      (Just historyWatermarks)
      defaultPersona
      multimodal'
      historyTurns'
      origin'
      tz'
      brief
      skills'
      inFlight'
      s
      gm
  let plan = planContext limits snapshot
      MessageId triggerMessageId = gm.messageId
      scope = conversationScopeFor gm.groupId
  traceStored <-
    trySync $
      recordContextPlanTrace
        scope
        triggerMessageId
        (contextReadModeText readMode)
        plan.cpPolicyVersion
        plan.cpMaterializationVersion
        plan.cpMaterializationReason
        plan.cpBudget
        plan.cpEstimatedPromptTokens
        plan.cpWithinBudget
        plan.cpTrace
  case traceStored of
    Left err ->
      logAttention "context: failed to persist planning trace" $
        object ["group_id" .= (let GroupId groupId = gm.groupId in groupId), "error" .= T.pack (show err)]
    Right () -> pure ()
  when (not plan.cpWithinBudget) $
    logAttention "context plan exceeds model input budget" $
      object
        [ "estimated_prompt_tokens" .= plan.cpEstimatedPromptTokens,
          "prompt_token_limit" .= plan.cpBudget.cbPromptTokenLimit,
          "policy_version" .= plan.cpPolicyVersion
        ]
  pure (renderContextPlan plan)

contextReadModeText :: ContextReadMode -> Text
contextReadModeText = \case
  TieredContext -> "tiered"
  RawLedgerEmergency -> "raw_emergency"

-- | Effectful I/O only: fetch and enrich a complete snapshot.  Selection and
-- token pressure happen later in the pure policy step.
collectContext ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  Bool ->
  Bool ->
  TriggerOrigin ->
  TimeZone ->
  [Text] ->
  [(Text, Text)] ->
  Set Int64 ->
  Session ->
  GroupMessage ->
  Eff es ContextSnapshot
collectContext = collectContextWithWatermarks TieredContext Nothing

collectContextWithWatermarks ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ContextReadMode ->
  Maybe HistoryTokenWatermarks ->
  Text ->
  Bool ->
  Bool ->
  TriggerOrigin ->
  TimeZone ->
  [Text] ->
  [(Text, Text)] ->
  Set Int64 ->
  Session ->
  GroupMessage ->
  Eff es ContextSnapshot
collectContextWithWatermarks readMode materializationWatermarks defaultPersona multimodal' historyTurns' origin' tz' brief skills' inFlight' s gm = do
  let GroupId gid = gm.groupId
      MessageId mid = gm.messageId
      UserId selfId' = gm.selfId
      UserId senderId = gm.userId
      scope = conversationScopeFor gm.groupId
  now' <- liftIO getCurrentTime
  -- Every conversation uses one chronological stream.  The normal path is a
  -- gap-free active compartment suffix followed by its exact raw tail.  If no
  -- projection is ready, or its materialization is unavailable, the global
  -- emergency fallback reads the immutable ledger from the beginning and lets
  -- ContextPolicy retain as much as the selected model's token budget allows.
  -- No mention/participation lane and no fixed message count survive here.
  let rawCollectionLimit = maybe 12288 (.htwHigh) materializationWatermarks
      collectRawFallback reason = do
        (raw, _) <- fetchBoundedPromptTail scope (MessageCursor 0) mid s.clearedAt rawCollectionLimit
        pure ([], map (.history) raw, Nothing, Just reason)
      collectProjectionFallback reason covered = do
        (raw, _) <- fetchBoundedPromptTail scope (last covered).activeRange.srEnd mid s.clearedAt rawCollectionLimit
        pure
          ( applyBaseCompartmentTiers now' (map contextCompartmentFromActive covered),
            map (.history) raw,
            Nothing,
            Just reason
          )
  (compartments', transcript', materializationVersion, materializationReason) <- case readMode of
    RawLedgerEmergency -> do
      logAttention "context: global raw-ledger emergency reader enabled" $
        object ["group_id" .= gid]
      collectRawFallback "operator_forced_raw_fallback"
    TieredContext -> do
      active <- listActiveCompartments scope
      let visibleAfterClear = case s.clearedAt of
            Nothing -> active
            Just cleared -> filter ((> cleared) . (.activeStartedAt)) active
          covered = latestGapFreeSuffix visibleAfterClear
          watermarks = fromMaybe (HistoryTokenWatermarks 6144 12288) materializationWatermarks
      case covered of
        [] -> do
          logInfo "context: no active compartment; using token-budgeted raw fallback" $
            object ["group_id" .= gid]
          collectRawFallback "raw_fallback_no_compartments"
        _ -> do
          when (any (.activeGapBefore) (drop 1 covered)) $
            logAttention "context: invalid gap inside selected compartment suffix" $
              object ["group_id" .= gid]
          materializeResult <-
            trySync $
              materializeTieredHistory
                scope
                mid
                s.clearedAt
                now'
                watermarks
                covered
          case materializeResult of
            Left err -> do
              logAttention "context: tiered materialization failed; using last-known-good projection" $
                object ["group_id" .= gid, "error" .= T.pack (show err)]
              collectProjectionFallback "last_known_good_projection_fallback" covered
            Right (materialized, rawTail) ->
              pure
                ( materializedCompartments covered materialized,
                  map (.history) rawTail,
                  Just materialized.cmRevision,
                  Just materialized.cmReason
                )
  pinnedItems' <- fetchMessagesByIdsInScope scope s.pinned
  -- Injection is capped to the freshest entries per scope: the block
  -- is in the volatile tail, re-tokenised at full price every
  -- dispatch, and a scope at the 30-entry cap was costing thousands
  -- of uncached tokens.  The long tail stays reachable through
  -- memory_list / memory_search.
  groupMems <- listRecentMemories (groupMemoryNamespace scope) memoryInjectCap
  userMems <- listRecentMemories (userMemoryNamespace scope senderId) memoryInjectCap
  replyCtx0 <- case extractReply gm.message of
    Nothing -> pure Nothing
    Just rid -> do
      mHist <- fetchMessageInScope scope rid
      case mHist of
        Nothing -> pure Nothing
        Just h -> do
          files <- DBFiles.fetchFilesForMessageInScope scope h.messageId
          -- Expand a quoted 转发聊天记录: its contents were filed by
          -- the forward worker as child rows.  Empty for ordinary
          -- messages — one cheap indexed lookup either way.
          kids <- fetchForwardChildrenInScope scope h.messageId maxForwardLines
          pure (Just (h, files, kids))
  -- Context stickers the caption worker has already described read
  -- as [sticker#<id>: <caption>] instead of an opaque [sticker]
  -- marker — a non-multimodal model gets to "see" them, and a
  -- multimodal one saves image budget for real photos.
  let ctxIds =
        map (.messageId) $
          transcript'
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
      transcript'' = map enrich transcript'
      pinnedItems'' = map enrich pinnedItems'
      replyCtx' = fmap (\(r, f, kids) -> (enrich r, f, map enrich kids)) replyCtx0
      replyItems = maybe [] (\(r, _, kids) -> r : kids) replyCtx'
  -- Unrelated pictures in the ambient chatter are attention magnets:
  -- only images the user is plausibly pointing at (reply target, the
  -- trigger itself, pins) go inline.  Everything else keeps a text
  -- marker, upgraded with the message id ("[image#123]") so the model
  -- can pull it via the view_image tool when it actually matters.
  transcriptCtx <-
    if multimodal'
      then do
        let inlineIds =
              Set.fromList (mid : map (.messageId) (replyItems <> pinnedItems''))
            taggable =
              [ h.messageId
              | h <- transcript'',
                h.messageId `Set.notMember` inlineIds
              ]
        tagIds <- messagesWithImages taggable
        pure (map (tagImageMarkers imgCaps tagIds) transcript'')
      else pure transcript''
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
        map enrich <$> fetchForwardChildrenInScope scope mid maxForwardLines
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
        take maxPromptVideos . concat <$> traverse loadMessageVideos cands
      else pure []
  pure $
    ContextSnapshot
      { csInputs =
          PromptInputs
            { defaultPersona = defaultPersona,
              session = s,
              triggerMessage = gm,
              transcript = transcriptCtx,
              compartments = compartments',
              historyTurns = historyTurns',
              inFlight = inFlight',
              pinnedItems = pinnedItems'',
              replyCtx = replyCtx',
              triggerForward = triggerKids,
              multimodal = multimodal',
              origin = origin',
              groupBrief = brief,
              groupMemories = groupMems,
              userMemories = userMems,
              images = images' <> videos',
              skills = skills',
              now = now',
              tz = tz'
            },
        csMaterializationVersion = materializationVersion,
        csMaterializationReason = materializationReason
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
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  (Int64, Text) -> -- (message_id, attachment label prefix, sans colon)
  Eff es [PromptImage]
loadMessageVideos (mid, label) = do
  rows <-
    query
      "SELECT v.mime_type, v.sha256, v.duration_seconds \
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
    loadOne (mime, sha, mDur) = case blobRefFromSha256 sha of
      Nothing -> do
        logAttention "prompt: invalid video blob ref" $ object ["sha256" .= sha]
        pure []
      Just ref -> do
        eres <- try @IOException (readBlob ref)
        case eres of
          Left e -> do
            logAttention "prompt: video read failed" $
              object ["sha256" .= sha, "error" .= T.pack (show e)]
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
-- Rendered text shows mentions as [@#<QQ号>] tokens (the wire
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
                pi'.transcript
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
applyVideoCaptions :: Map.Map Int64 [(Maybe Text, Maybe Text)] -> HistoryItem -> HistoryItem
applyVideoCaptions caps h = case Map.lookup h.messageId caps of
  Nothing -> h
  Just ds -> h {renderedText = go ds h.renderedText}
  where
    marker = "[video#" <> T.pack (show h.messageId) <> "]"
    go [] t = t
    go ((mDesc, mAttr) : ds) t = case T.breakOn marker t of
      (_, "") -> t
      (pre, suf) ->
        pre
          <> "[video#"
          <> T.pack (show h.messageId)
          <> maybe "" (\d -> ": " <> T.take 120 d) mDesc
          <> "]"
          <> maybe "" (\a -> "(" <> a <> ")") mAttr
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
  Eff es (Map.Map Int64 [(Maybe Text, Maybe Text)])
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
    -- (colon-slot description, paren-slot attribute) — duration is
    -- metadata, not content, so it rides the attribute group:
    -- "[video#7407: 首帧…](29秒)".
    capText mDesc mDur = (mDesc, fmtDurationSec <$> mDur)

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
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  TimeZone -> -- display timezone for the image labels' HH:MM
  Int64 -> -- bot self id (for display names in labels)
  Int64 -> -- trigger message_id
  Set.Set Int64 -> -- message ids belonging to the quoted reply (incl. forward children)
  [HistoryItem] -> -- context candidates, priority order, deduped
  Eff es [PromptImage]
loadPromptImages tz' selfId' mid replyIds candidates = do
  let candidates' = filter (\h -> h.messageId /= mid) candidates
      ids = mid : map (.messageId) candidates'
  rows <-
    query
      "SELECT mi.message_id, i.mime_type, i.sha256 \
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
      (triggerPicked, contextUnsorted) = partitionEithers picked
      contextPicked = sortOn (\(h, _) -> h.receivedAt) contextUnsorted
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
    loadOne label (mime, sha) = case blobRefFromSha256 sha of
      Nothing -> do
        logAttention "prompt: invalid image blob ref" $ object ["sha256" .= sha]
        pure []
      Just ref -> do
        eres <- try @IOException (readBlob ref)
        case eres of
          Right bytes0 -> do
            (mime', bytes) <- liftIO (prepareImageForLLM mime bytes0)
            if BS.length bytes > maxImageBytes
              then do
                logAttention "prompt: image skipped (too large)" $
                  object ["sha256" .= sha, "bytes" .= BS.length bytes]
                pure []
              else
                let b64 = TE.decodeUtf8 (B64.encode bytes)
                 in pure [PromptImage label ("data:" <> mime' <> ";base64," <> b64)]
          Left e -> do
            logAttention "prompt: image read failed" $
              object ["sha256" .= sha, "error" .= T.pack (show e)]
            pure []

-- | Pure transformation from fetched inputs to the chat-message list
-- the LLM sees.
--
-- Structure:
--
--   * @system@ message: persona + format guide.
--   * One chronological stream of compartments plus raw messages.
--   * One final @user@ message containing that stream, the reply chain,
--     pinned messages, and the current trigger.
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
                 "  成员对照（[@#QQ号] 即 @某人）："
                   <> T.intercalate "、" ["[@#" <> T.pack (show u) <> "]=" <> n | (u, n) <- roster]
               ]
      -- Questions somebody else's turn is already handling never reach
      -- the model, whichever shape we build.
      visible = dropInFlight selfId' pi'.inFlight pi'.transcript
      -- Flat: everything goes in the user body.  Turns: everything up
      -- to the bot's last message becomes turns, the rest rejoins the
      -- user body so the turn list ends on an assistant.
      (turnRows, bodyRows)
        | pi'.historyTurns = splitTrailingUser selfId' visible
        | otherwise = ([], visible)
      mTranscript
        | pi'.historyTurns = if null bodyRows then Nothing else Just bodyRows
        | otherwise = Just bodyRows
      userBody =
        renderUser
          pi'.tz
          pi'.now
          selfId'
          pi'.origin
          pi'.compartments
          mTranscript
          envText
          memBlock
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
      -- Default: system prompt then one user message, nothing else.
      -- Prior bot replies live in the transcript as ordinary lines
      -- rather than 'MsgAssistant' turns — see 'PromptInputs.transcript'
      -- for why the roles were a lie in a group, and note that this
      -- also removes the last way two consecutive same-role messages
      -- could reach a strict provider: there is exactly one of each.
      messages =
        [MsgSystem (systemPrompt pi'.multimodal (isPrivateChat pi'.triggerMessage.groupId) effectivePersona pi'.skills)]
          <> historyTurnMessages pi'.tz selfId' turnRows
          <> [userMessage]
   in messages

-- | Pure policy: enforce the selected model's token ceiling.  Optional active
-- memories go first under pressure,
-- followed by the oldest unpinned raw transcript rows; explicit permanent
-- memories are the final degradable source.  Reply targets, pins, the current
-- message, environment, and attached media are protected here.
planContext :: ContextLimits -> ContextSnapshot -> ContextPlan
planContext limits snapshot =
  let initial = snapshot.csInputs
      budget = contextBudget limits (not (null initial.images))
      (selected, drops) = fitContextTo budget.cbPromptTokenLimit initial
      messages = renderContext selected
      estimated = estimateMessagesTokens messages
      withinBudget = estimated <= budget.cbPromptTokenLimit
   in ContextPlan
        { cpInputs = selected,
          cpBudget = budget,
          cpEstimatedPromptTokens = estimated,
          cpWithinBudget = withinBudget,
          cpTrace = materializationTrace snapshot <> contextTrace budget selected messages drops withinBudget,
          cpPolicyVersion = contextPolicyVersion,
          cpMaterializationVersion = snapshot.csMaterializationVersion,
          cpMaterializationReason = snapshot.csMaterializationReason
        }

materializationTrace :: ContextSnapshot -> [ContextTrace]
materializationTrace snapshot = case snapshot.csMaterializationVersion of
  Nothing -> []
  Just revision ->
    [ ContextTrace
        "history.materialization"
        0
        ContextIncluded
        ( "revision="
            <> T.pack (show revision)
            <> maybe "" (" reason=" <>) snapshot.csMaterializationReason
        )
    ]

-- | Stable, LLM-free generational decay.  Wall-clock age is rounded into
-- coarse thresholds, while episode distance and importance keep recent or
-- consequential episodes at higher fidelity.  Topic relevance belongs in the
-- volatile recall lane and deliberately does not rewrite this prefix.
applyBaseCompartmentTiers :: UTCTime -> [ContextCompartment] -> [ContextCompartment]
applyBaseCompartmentTiers now' compartments' =
  [ compartment {contextTier = baseTier distance compartment}
  | (distance, compartment) <- zip [count - 1, count - 2 .. 0] compartments'
  ]
  where
    count = length compartments'
    ageDays compartment =
      max 0 (realToFrac (diffUTCTime now' compartment.contextEndedAt) / 86400 :: Double)
    baseTier distance compartment
      | compartment.contextImportance >= 0.9 = TierP1
      | ageDays compartment <= 7 && compartment.contextConfidence >= 0.5 = TierP1
      | distance <= 3 && ageDays compartment <= 30 && compartment.contextConfidence >= 0.5 = TierP1
      | compartment.contextImportance >= 0.7 = TierP2
      | ageDays compartment <= 30 = TierP2
      | distance <= 15 && ageDays compartment <= 90 = TierP2
      | compartment.contextImportance >= 0.4 = TierP3
      | ageDays compartment <= 180 = TierP3
      | distance <= 63 && ageDays compartment <= 365 = TierP3
      | otherwise = TierP4

renderContextPlan :: ContextPlan -> [ChatMessage]
renderContextPlan = renderContext . (.cpInputs)

data PolicyDrop = PolicyDrop
  { pdSource :: !Text,
    pdTokens :: !Int
  }

fitContextTo :: Int -> PromptInputs -> (PromptInputs, [PolicyDrop])
fitContextTo tokenLimit = go []
  where
    go dropped inputs
      | estimateMessagesTokens (renderContext inputs) <= tokenLimit = (inputs, reverse dropped)
      | Just (memory, withoutMemory) <- dropOldestMemory (== "active") inputs =
          go (memoryDrop "memory.active" memory : dropped) withoutMemory
      | Just (source, savedTokens, degraded) <- degradeOneCompartment inputs =
          go (PolicyDrop source savedTokens : dropped) degraded
      | oldest : rest <- inputs.transcript =
          let tokens = max 1 (estimateTextTokens oldest.renderedText)
           in go (PolicyDrop "history.raw" tokens : dropped) (inputs {transcript = rest})
      | Just (memory, withoutMemory) <- dropOldestMemory (== "permanent") inputs =
          go (memoryDrop "memory.permanent" memory : dropped) withoutMemory
      | otherwise = (inputs, reverse dropped)

degradeOneCompartment :: PromptInputs -> Maybe (Text, Int, PromptInputs)
degradeOneCompartment inputs = case filter ((/= TierP4) . (.contextTier)) inputs.compartments of
  [] -> Nothing
  candidates ->
    let selected = minimumBy (compare `on` degradationKey) candidates
        nextTier = succ selected.contextTier
        degraded = selected {contextTier = nextTier}
        oldTokens = maybe 0 estimateTextTokens (selectedCompartmentSummary selected)
        newTokens = maybe 0 estimateTextTokens (selectedCompartmentSummary degraded)
        source =
          "history.compartment."
            <> T.toLower (compartmentTierText selected.contextTier)
            <> "->"
            <> T.toLower (compartmentTierText nextTier)
     in Just
          ( source,
            max 1 (oldTokens - newTokens),
            inputs
              { compartments =
                  map
                    (\compartment -> if compartment.contextCompartmentId == selected.contextCompartmentId then degraded else compartment)
                    inputs.compartments
              }
          )
  where
    degradationKey compartment =
      ( compartment.contextImportance,
        compartment.contextEndedAt,
        compartment.contextMaterializationVersion,
        compartment.contextCompartmentId
      )

memoryDrop :: Text -> MemoryItem -> PolicyDrop
memoryDrop source memory =
  PolicyDrop source (max 1 (estimateTextTokens memory.memContent))

dropOldestMemory :: (Text -> Bool) -> PromptInputs -> Maybe (MemoryItem, PromptInputs)
dropOldestMemory lifecycleMatches inputs = case candidates of
  [] -> Nothing
  _ ->
    let (lane, oldest) = minimumBy (compare `on` candidateKey) candidates
        without = case lane of
          GroupMemory -> inputs {groupMemories = removeMemory oldest.memId inputs.groupMemories}
          UserMemory -> inputs {userMemories = removeMemory oldest.memId inputs.userMemories}
     in Just (oldest, without)
  where
    candidates =
      [(GroupMemory, memory) | memory <- inputs.groupMemories, lifecycleMatches memory.memLifecycle]
        <> [(UserMemory, memory) | memory <- inputs.userMemories, lifecycleMatches memory.memLifecycle]
    candidateKey (lane, memory) = (memory.memUpdatedAt, memory.memId, lane)

data MemoryLane = GroupMemory | UserMemory
  deriving stock (Show, Eq, Ord)

removeMemory :: MemoryId -> [MemoryItem] -> [MemoryItem]
removeMemory target = filter ((/= target) . (.memId))

contextTrace :: ContextBudget -> PromptInputs -> [ChatMessage] -> [PolicyDrop] -> Bool -> [ContextTrace]
contextTrace budget inputs messages drops withinBudget =
  [ ContextTrace
      "prompt.total"
      (estimateMessagesTokens messages)
      (if withinBudget then ContextIncluded else ContextOverBudget)
      (if withinBudget then "within model input budget" else "protected prompt sources exceed model input budget"),
    ContextTrace
      "prompt.system"
      (systemTokens messages)
      ContextIncluded
      "stable persona, scene, format, and tool-use guidance",
    ContextTrace
      "history.raw"
      (sum [estimateTextTokens row.renderedText | row <- inputs.transcript])
      ContextIncluded
      "selected chronological raw transcript",
    ContextTrace
      "history.compartment"
      (sum (map compartmentSelectedTokens inputs.compartments))
      ContextIncluded
      "selected deterministic P1/P2/P3 chronological projections",
    ContextTrace
      "history.compartment.p4"
      0
      (if any ((== TierP4) . (.contextTier)) inputs.compartments then ContextDropped else ContextIncluded)
      "P4 episodes remain searchable and expandable but are omitted from the default prompt",
    ContextTrace
      "reply"
      (replyContextTokens inputs.replyCtx)
      ContextIncluded
      "explicit reply target, attached file metadata, and quoted forward children",
    ContextTrace
      "pin"
      (historyContentTokens inputs.pinnedItems)
      ContextIncluded
      "explicitly pinned source messages",
    ContextTrace
      "trigger_forward"
      (historyContentTokens inputs.triggerForward)
      ContextIncluded
      "forward children attached to the current trigger",
    ContextTrace
      "memory"
      (sum [estimateTextTokens memory.memContent | memory <- inputs.groupMemories <> inputs.userMemories])
      ContextIncluded
      "scoped active and permanent semantic memory",
    ContextTrace
      "environment"
      ( estimateTextTokens inputs.session.model
          + sum (map estimateTextTokens inputs.groupBrief)
          + sum [estimateTextTokens name | (_, name) <- contextRoster inputs]
      )
      ContextIncluded
      "current time, conversation, model, and roster",
    ContextTrace
      "current_message"
      (estimateTextTokens (renderPlainText inputs.triggerMessage.message))
      ContextIncluded
      "protected current trigger",
    ContextTrace
      "attachment"
      budget.cbAttachmentReserve
      ContextReserved
      "conservative reserve applied only when media blocks are attached",
    ContextTrace
      "tool_round"
      budget.cbToolRoundReserve
      ContextReserved
      "reserved for tool schemas and later agent rounds",
    ContextTrace
      "output"
      budget.cbReservedOutputTokens
      ContextReserved
      "profile completion limit tracked separately from the input ceiling"
  ]
    <> [ ContextTrace source tokens ContextDropped "removed deterministically under token pressure"
       | (source, tokens) <- Map.toAscList (Map.fromListWith (+) [(drop'.pdSource, drop'.pdTokens) | drop' <- drops])
       ]

compartmentSelectedTokens :: ContextCompartment -> Int
compartmentSelectedTokens = maybe 0 estimateTextTokens . selectedCompartmentSummary

systemTokens :: [ChatMessage] -> Int
systemTokens = \case
  MsgSystem content : _ -> estimateTextTokens content + 8
  _ -> 0

historyContentTokens :: [HistoryItem] -> Int
historyContentTokens = sum . map (estimateTextTokens . (.renderedText))

replyContextTokens :: Maybe (HistoryItem, [FileRecord], [HistoryItem]) -> Int
replyContextTokens = \case
  Nothing -> 0
  Just (reply, files, children) ->
    estimateTextTokens reply.renderedText
      + historyContentTokens children
      + sum [estimateTextTokens file.frFileName | file <- files]

-- | How many entries per scope the prompt carries.  Injection policy,
-- not a storage cap — 'Max.Tools.Memory.maxMemoriesPerScope' still
-- governs what a scope may hold.
memoryInjectCap :: Int
memoryInjectCap = 12

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
            "仅在与当前话题相关时参考，不要主动提及；记的是写下时的状态，可能已过期，\
            \与对话矛盾时以对话为准（可 memory_update）。只列最近更新的条目，\
            \更早或跨来源的用 context_search 查；只看记忆清单用 memory_list。"
          ],
          if null groupMems
            then []
            else (if private then "本会话:" else "本群:") : map (memoryLine tz') groupMems,
          if null userMems
            then []
            else ("关于当前发言者 <" <> senderName <> ">（本会话）:") : map (memoryLine tz') userMems
        ]

memoryLine :: TimeZone -> MemoryItem -> Text
memoryLine tz' m =
  "  (#"
    <> T.pack (show m.memId.unMemoryId)
    <> "@v"
    <> T.pack (show m.memVersion.unMemoryVersion)
    <> " "
    <> fmtDate tz' m.memUpdatedAt
    <> ") "
    <> oneLine m.memContent

-- | Keep the newest coverage island.  Explicit historical backfill may have
-- produced older active compartments separated from the live historian
-- cursor by raw rows; those projections remain searchable but cannot be
-- rendered as if the gap did not exist.
latestGapFreeSuffix :: [ActiveCompartment] -> [ActiveCompartment]
latestGapFreeSuffix compartments' = drop lastBreak compartments'
  where
    lastBreak =
      foldl
        (\latest (index, compartment) -> if compartment.activeGapBefore then index else latest)
        0
        (zip [0 ..] compartments')

contextCompartmentFromActive :: ActiveCompartment -> ContextCompartment
contextCompartmentFromActive active =
  ContextCompartment
    { contextCompartmentId = active.activeCompartmentId.unCompartmentId,
      contextExpandHandle = active.activeExpandHandle,
      contextStartedAt = active.activeStartedAt,
      contextEndedAt = active.activeEndedAt,
      contextImportance = active.activeImportance,
      contextConfidence = active.activeConfidence,
      contextMaterializationVersion = active.activeMaterializationVersion,
      contextSummaryP1 = active.activeSummaryP1,
      contextSummaryP2 = active.activeSummaryP2,
      contextSummaryP3 = active.activeSummaryP3,
      contextTier = TierP1
    }

contextPolicyVersion :: Text
contextPolicyVersion = "context-policy/v3"

materializeTieredHistory ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Maybe UTCTime ->
  UTCTime ->
  HistoryTokenWatermarks ->
  [ActiveCompartment] ->
  Eff es (ContextMaterialization, [LedgerItem])
materializeTieredHistory scope triggerId cleared now' watermarks active = do
  stored <- loadContextMaterialization scope
  current <- case stored of
    Nothing -> publishOrReload Nothing "initial_materialization" active
    Just materialization
      | not (materializationMatches active materialization) -> do
          let retained = filter ((<= materialization.cmEndCursor) . (.srEnd) . (.activeRange)) active
              replacement = if null retained then active else retained
          publishOrReload (Just materialization.cmRevision) "projection_change" replacement
      | otherwise -> pure materialization
  (tailRows, tailTruncated) <-
    fetchBoundedPromptTail scope current.cmEndCursor triggerId cleared watermarks.htwHigh
  if not tailTruncated && rawTailTokens tailRows <= watermarks.htwHigh
    then pure (current, tailRows)
    else case targetAtLowWater current tailRows active watermarks.htwLow of
      Nothing -> pure (current, tailRows)
      Just target -> do
        folded <- publishOrReload (Just current.cmRevision) "high_water" target
        (foldedTail, _) <-
          fetchBoundedPromptTail scope folded.cmEndCursor triggerId cleared watermarks.htwHigh
        pure (folded, foldedTail)
  where
    publishOrReload expected reason target = do
      let draft = materializationDraft now' watermarks.htwHigh reason target
      publishContextMaterialization scope expected draft >>= \case
        Just materialization -> pure materialization
        Nothing ->
          loadContextMaterialization scope >>= \case
            Just winner -> pure winner
            Nothing -> error "context materialization CAS lost without a stored winner"

materializationMatches :: [ActiveCompartment] -> ContextMaterialization -> Bool
materializationMatches active materialization =
  materialization.cmPolicyVersion == contextPolicyVersion
    && not (null owned)
    && length owned == length materialization.cmItems
    && (last owned).activeRange.srEnd == materialization.cmEndCursor
    && expectedItems == materialization.cmItems
  where
    owned = filter ((<= materialization.cmEndCursor) . (.srEnd) . (.activeRange)) active
    expectedItems =
      [ MaterializedCompartment
          compartment.activeCompartmentId
          compartment.activeMaterializationVersion
          stored.mcTier
      | (compartment, stored) <- zip owned materialization.cmItems
      ]

targetAtLowWater ::
  ContextMaterialization ->
  [LedgerItem] ->
  [ActiveCompartment] ->
  Int ->
  Maybe [ActiveCompartment]
targetAtLowWater current tailRows active lowWater = do
  let newer = filter ((> current.cmEndCursor) . (.srEnd) . (.activeRange)) active
  _ <- listToMaybe newer
  let chosen =
        fromMaybe
          (last newer)
          ( find
              (\compartment -> rawTailTokens (rowsAfter compartment.activeRange.srEnd) <= lowWater)
              newer
          )
  pure (filter ((<= chosen.activeRange.srEnd) . (.srEnd) . (.activeRange)) active)
  where
    rowsAfter cursor = filter ((> cursor) . (.cursor)) tailRows

materializationDraft :: UTCTime -> Int -> Text -> [ActiveCompartment] -> MaterializationDraft
materializationDraft now' compartmentBudget reason active =
  MaterializationDraft
    { mdEndCursor = (last active).activeRange.srEnd,
      mdPolicyVersion = contextPolicyVersion,
      mdItems = zipWith toStored active tiered,
      mdReason = reason
    }
  where
    tiered = fitCompartmentTiers compartmentBudget (applyBaseCompartmentTiers now' (map contextCompartmentFromActive active))
    toStored source planned =
      MaterializedCompartment
        { mcCompartmentId = source.activeCompartmentId,
          mcProjectionVersion = source.activeMaterializationVersion,
          mcTier = compartmentTierStorageText planned.contextTier
        }

fitCompartmentTiers :: Int -> [ContextCompartment] -> [ContextCompartment]
fitCompartmentTiers tokenLimit = go
  where
    go compartments'
      | sum (map compartmentSelectedTokens compartments') <= tokenLimit = compartments'
      | otherwise = case filter ((/= TierP4) . (.contextTier)) compartments' of
          [] -> compartments'
          candidates ->
            let selected = minimumBy (compare `on` degradationKey) candidates
                degraded = selected {contextTier = succ selected.contextTier}
             in go
                  [ if compartment.contextCompartmentId == selected.contextCompartmentId
                      then degraded
                      else compartment
                  | compartment <- compartments'
                  ]
    degradationKey compartment =
      ( compartment.contextImportance,
        compartment.contextEndedAt,
        compartment.contextMaterializationVersion,
        compartment.contextCompartmentId
      )

materializedCompartments :: [ActiveCompartment] -> ContextMaterialization -> [ContextCompartment]
materializedCompartments active materialization = mapMaybe materialize materialization.cmItems
  where
    byId = Map.fromList [(compartment.activeCompartmentId, compartment) | compartment <- active]
    materialize stored = do
      source <- Map.lookup stored.mcCompartmentId byId
      tier <- compartmentTierFromStorageText stored.mcTier
      pure (contextCompartmentFromActive source) {contextTier = tier}

rawTailTokens :: [LedgerItem] -> Int
rawTailTokens =
  sum
    . map
      (\entry -> 8 + estimateTextTokens entry.history.renderedText)

-- | Collect only the newest token-sized raw tail.  SQL pages are walked
-- backward so an arbitrarily old ledger never has to enter memory merely to
-- be dropped by ContextPolicy.  The final page may overshoot the token target;
-- the pure policy remains the authoritative exact selection boundary.
fetchBoundedPromptTail ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  Int64 ->
  Maybe UTCTime ->
  Int ->
  Eff es ([LedgerItem], Bool)
fetchBoundedPromptTail scope after triggerId cleared tokenLimit = go Nothing [] 0
  where
    go before accumulated used = do
      page <- fetchNewestPromptPageBefore scope after before triggerId cleared promptTailPageSize
      let rows = page.items
          accumulated' = rows <> accumulated
          used' = used + rawTailTokens rows
      case rows of
        [] -> pure (accumulated, False)
        oldest : _
          | page.hasMore && used' < max 1 tokenLimit ->
              go (Just oldest.cursor) accumulated' used'
          | otherwise -> pure (accumulated', page.hasMore)

-- Internal database page size only; never a retained-message boundary.
promptTailPageSize :: Int
promptTailPageSize = 256

compartmentTierStorageText :: CompartmentTier -> Text
compartmentTierStorageText = T.toLower . compartmentTierText

compartmentTierFromStorageText :: Text -> Maybe CompartmentTier
compartmentTierFromStorageText = \case
  "p1" -> Just TierP1
  "p2" -> Just TierP2
  "p3" -> Just TierP3
  "p4" -> Just TierP4
  _ -> Nothing

-- | Drop the messages another turn is already answering.
--
-- Their real reply hasn't been written yet, so each would sit in the
-- context as a question with nothing after it — indistinguishable from
-- one the bot ignored, and the model duly answers it on top of the one
-- it was actually asked.  Both people then get the same answer, one of
-- them twice.
--
-- Hiding rather than annotating: an explanation of why a line should
-- be skipped is one more string in the prompt that the model has to
-- correctly read as not-speech, and the annotation that used to live
-- here failed exactly that way — it came back as the bot's reply.
-- Bot rows are never dropped; nothing puts the bot's own id in flight,
-- but losing its side of the conversation would be the worse failure.
dropInFlight :: Int64 -> Set Int64 -> [HistoryItem] -> [HistoryItem]
dropInFlight botId inFlight =
  filter (\h -> h.userId == botId || h.messageId `Set.notMember` inFlight)

-- | History as real @user@\/@assistant@ turns
-- ('PromptInputs.historyTurns').
--
-- Runs of consecutive same-side rows collapse into one message: the
-- group's chatter is mostly not the bot, so without this a group
-- transcript becomes a long run of consecutive @user@ messages, which
-- strict providers reject.  Non-bot rows keep the same
-- @[HH:MM \<name\> #\<id\>]:@ label the flat shape uses — the role says
-- only \"not the bot\", so in a group with N speakers the label is
-- still doing all the work of saying who spoke.
--
-- Bot rows go in verbatim, deliberately unlabelled: a
-- @[HH:MM Max #id]@ prefix in the assistant slot is the one thing most
-- likely to teach the model to open its own replies that way.  The
-- cost is that the bot's own messages have no quotable id in this
-- shape — the flat transcript is the only one where they do.
historyTurnMessages :: TimeZone -> Int64 -> [HistoryItem] -> [ChatMessage]
historyTurnMessages tz' botId =
  map render . groupBy ((==) `on` isBot)
  where
    isBot h = h.userId == botId
    render hs
      | all isBot hs = MsgAssistant (T.intercalate "\n\n" (map (.renderedText) hs))
      | otherwise = MsgUser (T.intercalate "\n" (map (renderHistoryLine tz' botId) hs))

-- | Split the transcript so the turn list ends on an assistant turn:
-- any non-bot rows trailing the bot's last message go back into the
-- final user message, which is itself a user turn.
--
-- Without this the handover from history to now is two consecutive
-- user messages — precisely the thing this shape exists to avoid, and
-- it happens on every turn where the last thing said wasn't said by
-- the bot, which in a group is most of them.
splitTrailingUser :: Int64 -> [HistoryItem] -> ([HistoryItem], [HistoryItem])
splitTrailingUser botId hs =
  let (revTail, revHead) = span (\h -> h.userId /= botId) (reverse hs)
   in (reverse revHead, reverse revTail)

renderUser ::
  TimeZone ->
  UTCTime -> -- now; the current message carries no timestamp of its own
  Int64 ->
  TriggerOrigin ->
  [ContextCompartment] ->
  -- | The conversation transcript, chronological — or 'Nothing' when
  -- it is being emitted as separate turns and the @[recent messages]@
  -- block should not appear here at all.
  Maybe [HistoryItem] ->
  Text -> -- environment block (volatile; goes after the transcript)
  Maybe Text -> -- memory block (volatile; likewise)
  Maybe (HistoryItem, [FileRecord], [HistoryItem]) ->
  [HistoryItem] -> -- pinned items, in user pin order
  [HistoryItem] -> -- trigger's own forward children (trigger IS a 转发)
  GroupMessage ->
  Text
renderUser tz' now' selfId' origin' compartments' mTranscript envText mMemBlock replyCtx' pinnedItems' triggerFwd' gm =
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
        renderCompartments tz' compartments',
        case mTranscript of
          Nothing -> []
          Just [] -> ["[recent messages]", "(无历史消息)"]
          Just hs -> "[recent messages]" : map (renderHistoryLine tz' selfId') hs,
        -- Everything above this line is meant to be byte-stable across
        -- dispatches so a provider's prefix cache can cover it; the
        -- clock and the per-turn roster necessarily aren't, so they go
        -- below.  Placing them next to the message they describe reads
        -- better anyway than a clock buried in the system prompt.
        ["", envText],
        maybe [] (\b -> ["", b]) mMemBlock,
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
              renderCurrentLine tz' now' gm
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
              renderCurrentLine tz' now' gm
            ]
              <> renderReplyForward tz' selfId' triggerFwd'
              <> [ "",
                   "请回复当前消息。"
                 ]
      ]

renderCompartments :: TimeZone -> [ContextCompartment] -> [Text]
renderCompartments tz' compartments' = case mapMaybe renderOne compartments' of
  [] -> []
  rows ->
    ["[earlier conversation — rebuildable chronological summaries]"]
      <> rows
      <> [""]
  where
    renderOne compartment = do
      summary <- selectedCompartmentSummary compartment
      pure $
        "[episode#"
          <> episodeHandleText compartment.contextExpandHandle
          <> " "
          <> fmtDate tz' compartment.contextStartedAt
          <> ".."
          <> fmtDate tz' compartment.contextEndedAt
          <> " "
          <> compartmentTierText compartment.contextTier
          <> "]: "
          <> oneLine summary

selectedCompartmentSummary :: ContextCompartment -> Maybe Text
selectedCompartmentSummary compartment = case compartment.contextTier of
  TierP1 -> Just compartment.contextSummaryP1
  TierP2 -> Just compartment.contextSummaryP2
  TierP3 -> Just compartment.contextSummaryP3
  TierP4 -> Nothing

compartmentTierText :: CompartmentTier -> Text
compartmentTierText = \case
  TierP1 -> "P1"
  TierP2 -> "P2"
  TierP3 -> "P3"
  TierP4 -> "P4"

renderHistoryLine :: TimeZone -> Int64 -> HistoryItem -> Text
renderHistoryLine tz' selfId' h =
  "["
    <> fmtHM tz' h.receivedAt
    <> " "
    <> displayName selfId' h
    <> " #"
    <> T.pack (show h.messageId)
    <> "]: "
    <> replyPrefix h
    <> oneLine h.renderedText

renderReplyLine :: TimeZone -> Int64 -> HistoryItem -> Text
renderReplyLine tz' selfId' h =
  "[↩ quoted "
    <> fmtHM tz' h.receivedAt
    <> " "
    <> displayName selfId' h
    <> " #"
    <> T.pack (show h.messageId)
    <> "]: "
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
        <> (case r.frBlobRef of Just _ -> "true"; Nothing -> "false")
    sizePart Nothing = ""
    sizePart (Just n) = ", bytes=" <> T.pack (show n)
    tquote t = "\"" <> t <> "\""

-- | The live message, rendered in exactly the shape 'renderHistoryLine'
-- uses.  One format for "a message in this conversation", whether it
-- arrived a minute ago or just now — the format guide documents that
-- one shape, and a second shape for the current line was a small lie
-- the model had to work around.
--
-- Takes the clock because a 'GroupMessage' carries no timestamp: it is
-- the message being handled right now, so "now" is its time.
renderCurrentLine :: TimeZone -> UTCTime -> GroupMessage -> Text
renderCurrentLine tz' now' gm =
  let txt = stripBotMention gm.selfId (renderPlainText gm.message)
      MessageId mid = gm.messageId
   in "["
        <> fmtHM tz' now'
        <> " "
        <> senderDisplayName gm
        <> " #"
        <> T.pack (show mid)
        <> "]: "
        <> T.strip txt

stripBotMention :: UserId -> Text -> Text
stripBotMention (UserId u) t =
  foldr
    (\m acc -> T.replace m "" acc)
    t
    -- Canonical token (with and without its trailing space), then the
    -- legacy bare form still present in old rows.
    ["[@#" <> uid <> "] ", "[@#" <> uid <> "]", "@" <> uid]
  where
    uid = T.pack (show u)

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
