-- | Process-local task records and observation-ordered context. The log and
-- polls retain the evidence; only an explicit context rewrite installs a
-- checkpoint. Ordinary polls never carry an independently accumulated history.
module Max.Context.Projection
  ( Cursor,
    NodeLog,
    emptyLog,
    logCursor,
    appendObservation,
    TaskRecord,
    newTaskRecord,
    recordPoll,
    recordResults,
    project,
    taskTranscript,
    ProjectionOptions (..),
    Projection (..),
    planProjection,
  )
where

import Data.Aeson (Value (..), decodeStrict')
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.Maybe (maybeToList)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Context.Working
import Max.LLM.Types (ChatMessage (..), ToolCall (..))
import Max.Media.Vision (evictMedia, fitVisionBudget)
import Max.ModelCatalog (ContextLimits (..))
import Max.Tool.Types (ToolSpec)

-- | A cut between entries, not a wall-clock timestamp. Zero precedes the log.
newtype Cursor = Cursor Int deriving stock (Eq, Ord, Show)

-- | Each entry is rendered once when observed. Assembly owns attribution and
-- routing; a log handed to a task contains only observations it may see.
-- Step 4 supplies these observations from the node's routed event log.
newtype NodeLog = NodeLog (Seq [ChatMessage]) deriving stock (Show)

emptyLog :: NodeLog
emptyLog = NodeLog Seq.empty

logCursor :: NodeLog -> Cursor
logCursor (NodeLog entries) = Cursor (Seq.length entries)

appendObservation :: [ChatMessage] -> NodeLog -> NodeLog
appendObservation [] nodeLog = nodeLog
appendObservation messages (NodeLog entries) = NodeLog (entries |> messages)

-- | The frozen initial prompt includes the trigger and its conversation window.
-- Outputs and results belong to polls, never to the observation log.
data TaskRecord = TaskRecord
  { base :: !Cursor,
    window :: ![ChatMessage],
    polls :: !(Seq Poll),
    checkpoint :: !(Maybe Checkpoint)
  }
  deriving stock (Show)

data Poll = Poll
  { observed :: !Cursor,
    output :: !(Maybe ChatMessage),
    results :: ![ChatMessage]
  }
  deriving stock (Show)

-- | A deliberate prefix rewrite (compaction, media eviction or protected skill
-- restoration). It covers complete polls and observations through one cut;
-- later outputs/results and observations are still projected from the record.
-- Raw evidence remains in the log/polls, and taskTranscript ignores this cache.
data Checkpoint = Checkpoint !Int !Cursor ![ChatMessage] deriving stock (Show)

newTaskRecord :: Cursor -> [ChatMessage] -> TaskRecord
newTaskRecord cursor messages = TaskRecord cursor messages Seq.empty Nothing

recordPoll :: Cursor -> Maybe ChatMessage -> TaskRecord -> TaskRecord
recordPoll cursor response record = record {polls = record.polls |> Poll cursor response []}

-- | Results are delivered after the raw assistant message, in protocol order.
-- Even observations logged while a call runs appear after this result group.
recordResults :: [ChatMessage] -> TaskRecord -> TaskRecord
recordResults messages record = case Seq.viewr record.polls of
  Seq.EmptyR -> error "recordResults without a model poll"
  earlier Seq.:> poll -> record {polls = earlier |> poll {results = poll.results <> messages}}

project :: NodeLog -> TaskRecord -> Cursor -> [ChatMessage]
project nodeLog record cursor = case record.checkpoint of
  Nothing -> record.window <> taskTranscript nodeLog record cursor
  Just (Checkpoint count cut prefix) -> prefix <> projectPolls nodeLog cut (toList (Seq.drop count record.polls)) cursor

-- | Full within-task evidence, independent of context compaction and excluding
-- the initial conversation. This also supplies the existing AgentResult trail.
taskTranscript :: NodeLog -> TaskRecord -> Cursor -> [ChatMessage]
taskTranscript nodeLog record = projectPolls nodeLog record.base (toList record.polls)

projectPolls :: NodeLog -> Cursor -> [Poll] -> Cursor -> [ChatMessage]
projectPolls nodeLog = go
  where
    go previous [] current = between previous current
    go previous (poll : rest) current =
      between previous poll.observed
        <> maybeToList poll.output
        <> poll.results
        <> go poll.observed rest current
    between (Cursor start) (Cursor end) = case nodeLog of
      NodeLog entries -> concat (toList (Seq.take (max 0 (end - start)) (Seq.drop start entries)))

data ProjectionOptions = ProjectionOptions
  { limits :: !ContextLimits,
    anchor :: !(Maybe UsageAnchor),
    identity :: !Text,
    handle :: !Text,
    previousSummary :: !Text,
    skillInstructions :: ![Text],
    tools :: ![ToolSpec],
    removeMedia :: !Bool
  }

data Projection = Projection
  { working :: !WorkingProjection,
    record :: !TaskRecord,
    evictedMedia :: !Int,
    hasMedia :: !Bool
  }

-- | All input shaping happens here. Request execution and usage/admission
-- accounting stay in the agent. A media-rejection retry changes only options,
-- so it cannot accidentally append an observation or replay a tool result.
planProjection :: ProjectionOptions -> NodeLog -> TaskRecord -> Cursor -> Either Text Projection
planProjection options nodeLog record cursor = do
  plan <- fitWorkingContext options.limits options.anchor options.identity options.handle options.previousSummary visible options.tools
  let nextRecord
        | map messageFingerprint messages == map messageFingerprint plan.wpMessages = record
        | otherwise = record {checkpoint = Just (Checkpoint (Seq.length record.polls) cursor plan.wpMessages)}
  pure (Projection plan nextRecord (visionEvicted + forcedEvicted) (snd (evictMedia maxBound plan.wpMessages) > 0))
  where
    messages = project nodeLog record cursor
    restored = restoreSkills options.skillInstructions messages
    (vision, visionEvicted) = maybe (restored, 0) (`fitVisionBudget` restored) options.limits.visionLimits
    (visible, forcedEvicted) = if options.removeMedia then evictMedia maxBound vision else (vision, 0)

restoreSkills :: [Text] -> [ChatMessage] -> [ChatMessage]
restoreSkills loaded messages =
  if map messageFingerprint currentFrames == map messageFingerprint skillFrames
    then messages
    else takeWhile systemMessage withoutSkills <> skillFrames <> dropWhile systemMessage withoutSkills
  where
    -- Protect native use_skill outputs without duplicating their instructions.
    -- A skill loaded inside a guest has no native result and needs this frame.
    visibleInstructions = nativeSkillInstructions messages
    missingInstructions = [loadedText | loadedText <- loaded, not (any (loadedText `T.isInfixOf`) visibleInstructions)]
    instructions = T.intercalate "\n\n" missingInstructions
    skillPrefix = "[当前已加载宿主技能]\n"
    withoutSkills = filter (\case MsgUser text -> not (skillPrefix `T.isPrefixOf` text); _ -> True) messages
    skillFrames = [MsgUser (skillPrefix <> instructions) | not (T.null instructions)]
    currentFrames = [m | m@(MsgUser text) <- messages, skillPrefix `T.isPrefixOf` text]
    systemMessage MsgSystem {} = True
    systemMessage _ = False

-- Match each result to its own protocol round, since providers may reuse ids.
nativeSkillInstructions :: [ChatMessage] -> [Text]
nativeSkillInstructions = go []
  where
    go _ [] = []
    go _ (MsgAssistantToolCalls _ calls : rest) = go [call.callId | call <- calls, call.callName == "use_skill"] rest
    go pending (MsgTool cid body : rest)
      | cid `elem` pending,
        Just (Object value) <- decodeStrict' (TE.encodeUtf8 body),
        Just (String instructions) <- KeyMap.lookup "instructions" value =
          instructions : go pending rest
    go pending (_ : rest) = go pending rest
