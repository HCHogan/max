-- |
-- Semantic values passed between context collection, pure selection, and
-- prompt rendering.  These types deliberately contain no effects or store
-- handles, so every pipeline stage can be invoked and tested independently.
module Max.Context.Types
  ( PromptInputs (..),
    ContinuationInput (..),
    noContinuation,
    digestOnlyContinuation,
    ContextCandidates (..),
    SelectedContext (..),
    TriggerOrigin (..),
    ContextReadMode (..),
    CompartmentTier (..),
    ContextCompartment (..),
    PromptImage (..),
    ContextSnapshot (..),
    csInputs,
    ContextPlan (..),
    cpInputs,
    HistoryTokenWatermarks (..),
  )
where

import Data.Int (Int64)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (TimeZone, UTCTime)
import Max.Context (ContextBudget, ContextTrace)
import Max.DB.Files (FileRecord)
import Max.DB.History (HistoryItem)
import Max.Dispatch (DispatchMessage)
import Max.EpisodeStore (EpisodeHandle)
import Max.LLM.Types (ChatMessage)
import Max.MemoryStore (MemoryItem)
import Max.Platform.Types (AdvertisedCaps)
import Max.Session (Session)

-- | What one continuation contributes to a prompt.  The digest view is the
-- always-available floor; segments and their covered ids are present only
-- when the replay tier's validity predicate admitted them, so a caller that
-- cannot replay simply passes 'digestOnlyContinuation'.
data ContinuationInput = ContinuationInput
  { ciView :: !(Maybe Text),
    ciSegments :: ![ChatMessage],
    ciCovered :: !(Set Int64)
  }

-- | No continuation at all — an ordinary turn.
noContinuation :: ContinuationInput
noContinuation = ContinuationInput Nothing [] Set.empty

-- | A resolved continuation that stayed at the digest tier.
digestOnlyContinuation :: Maybe Text -> ContinuationInput
digestOnlyContinuation view = ContinuationInput view [] Set.empty

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
    triggerMessage :: !DispatchMessage,
    -- | Recent tool-using durable turns, newest first.  Lines carry scoped
    -- t# handles and are independently removable by ContextPolicy.
    recentTurns :: ![Text],
    -- | Host-authored digest for an exact reply continuation.  It is part of
    -- the selected prompt (rather than appended afterward) so token planning
    -- and diagnostics account for it.
    continuationView :: !(Maybe Text),
    -- | ADR 005 replay tier: archived wire items from the fork-from chain,
    -- oldest first, spliced between the current system prompt and the
    -- conversation window.  Empty at the digest tier, which is the floor.
    replaySegments :: ![ChatMessage],
    -- | Ledger rows the segments above already show verbatim.  They are cut
    -- from the ordinary window so one utterance never appears twice in two
    -- registers — the same reasoning as 'inFlight', a different cause.
    replayCovered :: !(Set Int64),
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
    -- | Portable semantic output surface shared by every enabled endpoint in
    -- this conversation.  Prompt actions must be a subset of this record;
    -- delivery adapters are not allowed to guess from compatibility ids.
    outputCapabilities :: !AdvertisedCaps,
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
    -- synthesized dispatch trigger has no message id or text.
    OriginPoke
  | -- | A durable ADR 006 monitor fire opened a fresh ordinary turn.
    -- Goal and trigger evidence live in the host-authored continuation view;
    -- the world event is not presented as user speech.
    OriginMonitor
  | OriginTask
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

newtype ContextCandidates = ContextCandidates
  { candidateInputs :: PromptInputs
  }

newtype SelectedContext = SelectedContext
  { selectedInputs :: PromptInputs
  }

-- | Complete output of the effectful collection step, before pure selection.
data ContextSnapshot = ContextSnapshot
  { csCandidates :: !ContextCandidates,
    csMaterializationVersion :: !(Maybe Int64),
    csMaterializationReason :: !(Maybe Text)
  }

csInputs :: ContextSnapshot -> PromptInputs
csInputs = (.csCandidates.candidateInputs)

-- | Deterministic, fully selected context with its budget and decision trace.
-- Rendering this value performs no I/O and no further selection.
data ContextPlan = ContextPlan
  { cpSelected :: !SelectedContext,
    cpBudget :: !ContextBudget,
    cpEstimatedPromptTokens :: !Int,
    cpWithinBudget :: !Bool,
    cpTrace :: ![ContextTrace],
    cpPolicyVersion :: !Text,
    cpMaterializationVersion :: !(Maybe Int64),
    cpMaterializationReason :: !(Maybe Text)
  }

cpInputs :: ContextPlan -> PromptInputs
cpInputs = (.cpSelected.selectedInputs)

data HistoryTokenWatermarks = HistoryTokenWatermarks
  { htwLow :: !Int,
    htwHigh :: !Int
  }
