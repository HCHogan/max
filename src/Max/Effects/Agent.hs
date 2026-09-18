{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

-- | Multi-turn LLM loop with scoped tools and typed output events.
-- Each round reads pending input, calls the model, and either executes tools
-- or handles a content response under the turn's completion policy.
-- Streaming emits safe fragments and tracks the accepted prefix per call.
-- Handler owns the TurnRuntime and its cleanup; this interpreter installs
-- cancellation, checks it between steps, and consumes the execution inbox.
module Max.Effects.Agent
  ( Agent,
    AgentLimits (..),
    AgentResult (..),
    AgentContext (..),
    assembleToolRound,
    toolResultMessage,
    runAgentWith,
    agentTurn,
    defaultLimits,
  )
where

import Control.Concurrent (myThreadId, throwTo)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (unless, when)
import Data.Aeson (Value (..), decodeStrict', encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent.Async (Concurrent)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift, send)
import Effectful.Exception (throwIO)
import Effectful.Log
import Max.Agent.Execution
import Max.Agent.Failure (AgentFailure (..))
import Max.AgentEvent (AgentEvent (..), AgentEventSink, ToolDebugEvent (..))
import Max.CodeMode.Model (codeModeSpecs, executeModelBatch)
import Max.Context.Working
import Max.Effects.LLM (ChatCtx (..), ChatMessage (..), ChatResponse (..), ContentBlock (..), LLM, ToolCall (..), ToolSpec, chatMeasured)
import Max.Effects.ToolControl (ToolControl, runToolControl)
import Max.Effects.ToolDirectory (ToolDirectory, listCatalogTools, listToolSpecs, runToolDirectoryDynamic)
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, ToolOutputRead, defaultInlineMediaLimit, drainInlineMedia, newToolOutputQueue, runToolOutput, runToolOutputRead)
import Max.Effects.Tools
  ( ToolCatalogError,
    ToolInvocation (..),
    ToolRegistry,
    Tools,
    outcomeResult,
    registryCatalog,
    runToolsWithInvocationDynamic,
  )
import Max.Execution.Tools
import Max.Execution.Workflow (WorkflowHost)
import Max.Reply (readyPrefix)
import Max.Tasks
  ( TaskCancelled (..),
    TurnRuntime,
    activateTurnRuntime,
    checkTurnCancellation,
    setTurnPhase,
    turnRuntimeAgentTurn,
  )
import Max.Tool.Bundles (SkillLoad (..))
import Max.Tool.Control (LoopControl (..), controlReply, controlSkillLoads, mergeControls)
import Max.ToolContext (ToolContext, TurnCapabilities (..), toolCapabilities, toolContextLimits, toolGroupId, toolSkillLoads, toolTurnOutputContext, withToolInvocationIdentity, withToolSkillLoads)
import Max.Turn.Types (AgentTurnRef (..), turnHandleText, turnOutputAgentTurn)
import OneBot.Types (GroupId (..))

-- | Agent-only data around the neutral context handed to tools.
data AgentContext = AgentContext
  { acTools :: !ToolContext,
    -- | The session's @!effort@ override, threaded into every LLM
    -- call this turn makes ('turnCtx').  'Nothing' = the profile's
    -- configured effort.
    acEffort :: !(Maybe Text),
    acMaxToolCalls :: !(Maybe Int)
  }

-- | Usage attribution for a dispatch's own LLM calls.  Private chats
-- report their pseudo-group id — that is the conversation the spend
-- belongs to.
turnCtx :: AgentContext -> Text -> ChatCtx
turnCtx ctx source =
  let GroupId gid = toolGroupId ctx.acTools
      durable = (.atrTurnId) . turnOutputAgentTurn <$> toolTurnOutputContext ctx.acTools
   in ChatCtx (if (toolCapabilities ctx.acTools).tcBackground then "task/" <> source else source) (Just gid) ctx.acEffort Nothing Nothing durable

-- | Caps on a single agent invocation.  Per-tool and per-call HTTP
-- timeouts are configured at the 'LLM' layer; these are loop-level.
data AgentLimits = AgentLimits
  { -- | Maximum number of LLM round-trips per dispatch.  Counts each
    -- 'chat' call, whether it returned content or tool calls.
    maxTurns :: !Int
  }
  deriving stock (Show)

-- | Sane starting point: 1000 turns covers long multi-round sandbox
-- sessions with @say@ status updates interleaved, while still capping
-- runaway loops.  Hard cap to keep cost bounded.
defaultLimits :: AgentLimits
defaultLimits = AgentLimits {maxTurns = 1000}

-- | What one agent run produced.
data AgentResult = AgentResult
  { -- | Final assistant text to show the user.  'Nothing' when the
    -- loop produced no model-authored reply (LLM error, or the
    -- turn-cap fallback call failed too) — the caller signals failure
    -- out-of-band (reaction swap) instead of posting synthetic error
    -- text into the chat; the reason is in 'aborted'.
    reply :: !(Maybe Text),
    -- | Every message added to the conversation during this run —
    -- feedback injections, assistant tool-call rounds, tool results,
    -- final assistant text.  Does NOT include the initial messages
    -- the caller passed in.
    appended :: ![ChatMessage],
    turnsUsed :: !Int,
    -- | 'Just' iff the loop ended for a reason other than the model
    -- producing a content response (e.g. hit 'maxTurns', LLM error).
    aborted :: !(Maybe AgentFailure),
    -- | Verbatim prefix already accepted by the streaming sink; empty if none.
    -- The caller sends only @T.drop (T.length sentPrefix) reply@. 'readyPrefix'
    -- cuts at safe text boundaries, so this preserves the unsent tail.
    sentPrefix :: !Text
  }
  deriving stock (Show)

--------------------------------------------------------------------------------
-- Effect.

data Agent :: Effect where
  -- | Run until completion, a loop limit, or failure. The typed sink separates
  -- progress, debug facts and final text; rendering and delivery belong to it.
  AgentTurn ::
    TurnRuntime ->
    AgentContext ->
    Text ->
    [ChatMessage] ->
    AgentEventSink m ->
    Agent m AgentResult

type instance DispatchOf Agent = Dynamic

-- | Install scoped tools and drive the loop using the supplied admission,
-- journal and inbox interfaces. Visible output goes through the event sink.
runAgentWith ::
  forall es a.
  (LLM :> es, Concurrent :> es, Log :> es, IOE :> es) =>
  ExecutionAdmission es ->
  ExecutionJournal es ->
  ExecutionInbox es ->
  Maybe (ToolContext -> AgentTurnRef -> WorkflowHost es) ->
  AgentLimits ->
  (ToolContext -> Either ToolCatalogError (ToolRegistry (ToolOutput : ToolControl : es))) ->
  Eff (Agent : es) a ->
  Eff es a
runAgentWith admission journal inbox workflowHost lims toolFactory = interpret $ \localEnv -> \case
  AgentTurn turn ctx profile msgs sink -> localSeqUnlift localEnv $ \unlift -> do
    selfTid <- liftIO myThreadId
    previousWorking <- maybe (pure "") journal.ejReadWorking (turnRuntimeAgentTurn turn)
    workingRef <- liftIO (newTVarIO (Nothing, previousWorking))
    restored <- maybe (pure []) journal.ejReadSkillLoads (turnRuntimeAgentTurn turn)
    let context = ctx {acTools = withToolSkillLoads restored ctx.acTools}
        restoredInstructions = T.intercalate "\n\n" (map (.slInstructions) (Map.elems (toolSkillLoads context.acTools)))
        recoveryMessages = [MsgUser ("[恢复的宿主技能说明]\n" <> restoredInstructions) | not (T.null restoredInstructions)]
    catalog <- either throwIO pure (toolFactory context.acTools)
    catalogRef <- liftIO (newTVarIO (context.acTools, catalog))
    let cancel = throwTo selfTid TaskCancelled
        emit :: AgentEventSink (Eff (Tools : ToolDirectory : ToolOutputRead : es))
        emit event = raise (raise (raise (unlift (sink event))))
    -- Handler created this runtime before context collection and remains its
    -- sole finalizer.  Agent only activates the worker cancellation hook and
    -- consumes feedback through the explicit object.
    preKilled <- liftIO (activateTurnRuntime turn "llm" cancel)
    when preKilled $ throwIO TaskCancelled
    session <- newExecutionSession context.acMaxToolCalls
    outputQueue <- newToolOutputQueue defaultInlineMediaLimit
    runToolOutputRead outputQueue $
      runToolDirectoryDynamic (registryCatalog . snd <$> liftIO (readTVarIO catalogRef)) $
        runToolsWithInvocationDynamic
          (raise . raise . runToolControl . runToolOutput outputQueue)
          ( \identity -> do
              (current, _) <- liftIO (readTVarIO catalogRef)
              either throwIO pure (toolFactory (withToolInvocationIdentity identity current))
          )
          (loop workingRef session catalogRef emit context turn profile (msgs <> recoveryMessages))
  where
    loop ::
      TVar (Maybe UsageAnchor, Text) ->
      ExecutionSession ->
      TVar (ToolContext, ToolRegistry (ToolOutput : ToolControl : es)) ->
      AgentEventSink (Eff (Tools : ToolDirectory : ToolOutputRead : es)) ->
      AgentContext ->
      TurnRuntime ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : ToolDirectory : ToolOutputRead : es) AgentResult
    loop workingRef session catalogRef emit ctx h profile = go workingRef session catalogRef emit ctx h 0 [] profile

    go ::
      TVar (Maybe UsageAnchor, Text) ->
      ExecutionSession ->
      TVar (ToolContext, ToolRegistry (ToolOutput : ToolControl : es)) ->
      AgentEventSink (Eff (Tools : ToolDirectory : ToolOutputRead : es)) ->
      AgentContext ->
      TurnRuntime ->
      Int ->
      [ChatMessage] ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : ToolDirectory : ToolOutputRead : es) AgentResult
    go workingRef session catalogRef emit ctx h n appended profile msgs = do
      catalog <- either throwIO pure (toolFactory ctx.acTools)
      liftIO (atomically (writeTVar catalogRef (ctx.acTools, catalog)))
      -- Drain any feedback notes that arrived since the previous turn.
      liftIO (checkTurnCancellation h)
      durableNotes <- maybe (pure "") (raise . raise . raise . inbox.eiRead) (turnRuntimeAgentTurn h)
      let newNotes = durableInputMessages durableNotes
          msgs' = msgs <> newNotes
          appended' = appended <> newNotes
      if n >= lims.maxTurns
        then finalAnswer workingRef ctx h n appended' profile msgs'
        else do
          liftIO (setTurnPhase h "llm")
          nativeSpecs <- listToolSpecs
          let codeEnabled = (toolCapabilities ctx.acTools).tcSkills && Map.member "codemode" (toolSkillLoads ctx.acTools)
              specs = nativeSpecs <> codeModeSpecs codeEnabled
          -- Trim before the call AND carry the trimmed list forward
          -- (every recursion below builds on msgs''): stubs are
          -- permanent, so between trim events the list is byte-stable
          -- and the provider's prefix cache survives.
          -- Reset per call: one chat call is one utterance (a progress
          -- narration, or the final answer), and each gets its own
          -- prefix bookkeeping.
          sentRef <- liftIO (newTVarIO "")
          (msgs'', eres) <- budgetedCall workingRef ctx h profile "turn" msgs' specs (Just (releaseReplyPrefix emit sentRef))
          checkDurable h
          sent <- liftIO (readTVarIO sentRef)
          case eres of
            Left err ->
              pure
                AgentResult
                  { reply = Nothing,
                    appended = appended',
                    turnsUsed = n + 1,
                    aborted = Just err,
                    sentPrefix = sent
                  }
            Right (InterruptedResp text reason) ->
              pure
                AgentResult
                  { reply = Just text,
                    appended = appended' <> [MsgAssistant text],
                    turnsUsed = n + 1,
                    aborted = Just (AgentStreamInterrupted reason),
                    sentPrefix = sent
                  }
            Right (ContentResp text) -> do
              -- A feedback note that raced in during this final call
              -- would be lost — the task is released right after we
              -- return, and the reply it was meant to steer is already
              -- written.  If any arrived, loop instead: the unsent draft
              -- stays in the conversation and the model re-answers with
              -- the note in view.
              lateDurable <-
                if T.null sent
                  then maybe (pure "") (raise . raise . raise . inbox.eiRead) (turnRuntimeAgentTurn h)
                  else pure ""
              let lateMessages = durableInputMessages lateDurable
              let done =
                    pure
                      AgentResult
                        { reply = Just text,
                          appended = appended' <> [MsgAssistant text],
                          turnsUsed = n + 1,
                          aborted = Nothing,
                          sentPrefix = sent
                        }
              case lateMessages of
                [] -> done
                xs -> do
                  logInfo "agent: btw notes raced final answer, continuing" $
                    object ["count" .= length xs]
                  let newMsgs = MsgAssistant text : xs
                  go workingRef session catalogRef emit ctx h (n + 1) (appended' <> newMsgs) profile (msgs'' <> newMsgs)
            Right (ToolCallsResp raw narration tcs) -> do
              logInfo "agent: tool calls" $
                object
                  [ "turn" .= n,
                    "count" .= length tcs,
                    "names" .= map (.callName) tcs,
                    "narration" .= T.length narration
                  ]
              -- Whatever streaming already released of this narration is
              -- in the group; only the tail is left to post.  Rendering and
              -- visibility are output-boundary decisions.
              for_ (turnRuntimeAgentTurn h) $ \durable ->
                raise (raise (raise (journal.ejRecordNote durable narration)))
              emit (AgentProgressText (T.drop (T.length sent) narration))
              emit $
                AgentToolDebug $
                  ToolCallsStarted [(tc.callName, tc.callArguments) | tc <- tcs]
              liftIO (setTurnPhase h "tools")
              -- Carry the provider's message verbatim so its thinking
              -- output round-trips back to the API on the next
              -- request — DeepSeek returns 400 otherwise.
              -- Independent calls in one round run concurrently (DB
              -- goes through the pool, image attachment through STM);
              -- results keep call order so each tool_call id is
              -- answered in sequence.
              registered <- listCatalogTools
              let baseHooks = executionHooks admission journal (toolGroupId ctx.acTools) h
                  hooks = hoistExecutionHooks (raise . raise . raise) baseHooks {ehWorkflow = (\build durable -> build ctx.acTools durable) <$> workflowHost <*> turnRuntimeAgentTurn h}
                  requests = [ToolRequest tc.callId tc.callName tc.callArguments | tc <- tcs]
              for_ tcs $ \tc ->
                logInfo "agent: tool call" $ object ["id" .= tc.callId, "name" .= tc.callName, "args" .= previewJson 200 tc.callArguments]
              batch <- executeModelBatch codeEnabled (toolSkillLoads ctx.acTools) session hooks registered requests
              for_ (zip tcs batch.tbInvocations) $ \(tc, invocation) ->
                case outcomeResult invocation.tiOutcome of
                  Right value -> logInfo "agent: tool result" $ object ["id" .= tc.callId, "name" .= tc.callName, "outcome" .= outcomeName invocation.tiOutcome, "result" .= previewJson 400 value, "full_len" .= LBS.length (encode value)]
                  Left err -> logAttention "agent: tool failed" $ object ["id" .= tc.callId, "name" .= tc.callName, "outcome" .= outcomeName invocation.tiOutcome, "error" .= err]
              liftIO (checkTurnCancellation h)
              let executed = zipWith nativeResult tcs batch.tbInvocations
                  overBudget = batch.tbOverBudget
              -- Emit result facts after the concurrent round rejoins.  This
              -- keeps the higher-rank callback on its sequential unlift and
              -- gives debug output a deterministic call order.
              for_ executed $ \(_, event, _) -> emit (AgentToolDebug event)
              let toolMsgs = [message | (message, _, _) <- executed]
              imgs <- drainToolMedia
              let newMsgs = assembleToolRound raw tcs toolMsgs imgs
                  control = mergeControls [decision | (_, _, decision) <- executed]
                  nextContext = ctx {acTools = withToolSkillLoads (concatMap (\(_, _, decision) -> controlSkillLoads decision) executed) ctx.acTools}
              case controlReply control of
                Just finalReply ->
                  pure
                    AgentResult
                      { reply = finalReply,
                        appended = appended' <> newMsgs,
                        turnsUsed = n + 1,
                        aborted = Nothing,
                        sentPrefix = sent
                      }
                Nothing ->
                  if overBudget
                    then finalAnswer workingRef ctx h (n + 1) (appended' <> newMsgs) profile (msgs'' <> newMsgs)
                    else
                      go workingRef session catalogRef emit nextContext h (n + 1) (appended' <> newMsgs) profile (msgs'' <> newMsgs)

    budgetedCall ::
      TVar (Maybe UsageAnchor, Text) ->
      AgentContext ->
      TurnRuntime ->
      Text ->
      Text ->
      [ChatMessage] ->
      [ToolSpec] ->
      Maybe (Text -> Eff (Tools : ToolDirectory : ToolOutputRead : es) ()) ->
      Eff (Tools : ToolDirectory : ToolOutputRead : es) ([ChatMessage], Either AgentFailure ChatResponse)
    budgetedCall workingRef ctx turn profile source messages specs sink = do
      (anchor, previous) <- liftIO (readTVarIO workingRef)
      let limits = toolContextLimits ctx.acTools
          identity = workingIdentity profile "process" limits specs
          handle = maybe "unavailable" (turnHandleText . (.atrTurnOrdinal)) (turnRuntimeAgentTurn turn)
          -- Native use_skill results are protected by the working planner.
          -- Only restore instructions absent there (nested codemode/restart),
          -- avoiding a second full copy of every directly loaded skill.
          visibleInstructions = nativeSkillInstructions messages
          missingInstructions = [load.slInstructions | load <- Map.elems (toolSkillLoads ctx.acTools), not (any (load.slInstructions `T.isInfixOf`) visibleInstructions)]
          instructions = T.intercalate "\n\n" missingInstructions
          skillPrefix = "[当前已加载宿主技能]\n"
          withoutSkills = filter (\case MsgUser text -> not (skillPrefix `T.isPrefixOf` text); _ -> True) messages
          hasWorking = any (\case MsgUser text -> "[可恢复工作记录：" `T.isPrefixOf` text; _ -> False) messages
          skillFrames = [MsgUser (skillPrefix <> instructions) | not (T.null instructions)]
          currentFrames = [m | m@(MsgUser text) <- messages, skillPrefix `T.isPrefixOf` text]
          stableSkills =
            if map messageFingerprint currentFrames == map messageFingerprint skillFrames
              then messages
              else takeWhile systemMessage withoutSkills <> skillFrames <> dropWhile systemMessage withoutSkills
          systemMessage MsgSystem {} = True
          systemMessage _ = False
          prepared =
            stableSkills
              <> [MsgUser ("[可恢复工作记录：重启恢复，仅作证据；任务/journal 状态仍为准]\n" <> previous) | not hasWorking && not (T.null previous)]
      case fitWorkingContext limits anchor identity handle previous prepared specs of
        Left detail -> pure (prepared, Left (AgentContextBudget detail))
        Right plan
          | plan.wpCompacted && handle == "unavailable" ->
              pure (prepared, Left (AgentContextBudget "cannot prune a turn without a durable recovery handle"))
        Right plan -> do
          for_ (turnRuntimeAgentTurn turn) $ \durable -> do
            active <- raise (raise (raise (admission.eaReserveRound durable)))
            unless active (throwIO TaskCancelled)
            when plan.wpCompacted $ raise (raise (raise (journal.ejWriteWorking durable plan.wpSummary plan.wpEstimatedTokens plan.wpLimit)))
          when plan.wpCompacted $
            logInfo "agent: working context compacted" $
              object ["estimated_tokens" .= plan.wpEstimatedTokens, "input_limit" .= plan.wpLimit, "turn" .= handle]
          result <- chatMeasured (turnCtx ctx source) profile plan.wpMessages specs sink
          let nextAnchor = case result of
                Right (_, usage) -> observeUsage identity plan.wpMessages usage
                Left _ -> Nothing
          liftIO (atomically (writeTVar workingRef (nextAnchor, plan.wpSummary)))
          pure (plan.wpMessages, either (Left . AgentModelFailure) (Right . fst) result)

    -- Hit the turn cap: make one final tool-free chat call so the user
    -- gets a real answer built from whatever the loop already gathered,
    -- rather than a bare "max turns" error.  Empty tool specs force a
    -- content response; a synthetic note tells the model to wrap up.
    finalAnswer ::
      TVar (Maybe UsageAnchor, Text) ->
      AgentContext ->
      TurnRuntime ->
      Int ->
      [ChatMessage] ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : ToolDirectory : ToolOutputRead : es) AgentResult
    finalAnswer workingRef ctx h n appended profile msgs = do
      logInfo "agent: max turns reached, forcing final answer" $
        object ["turns" .= n]
      liftIO (checkTurnCancellation h)
      let capNote =
            MsgUser
              "[system] 工具调用轮次已用满，别再调用任何工具了。\
              \直接根据目前已经掌握的信息，给用户一个最终回复。"
      (_, eres) <- budgetedCall workingRef ctx h profile "wrapup" (msgs <> [capNote]) [] Nothing
      let (mText, ab) = case eres of
            Right (ContentResp t) | not (T.null (T.strip t)) -> (Just t, Just AgentRoundLimit)
            Right _ -> (Nothing, Just AgentRoundLimit)
            Left err -> (Nothing, Just err)
      pure
        AgentResult
          { reply = mText,
            appended = appended <> [capNote] <> [MsgAssistant t | Just t <- [mText]],
            turnsUsed = n + 1,
            aborted = ab,
            -- The wrap-up call is not streamed: it exists to salvage
            -- a turn that already went wrong, and one more moving part
            -- is the last thing that path needs.
            sentPrefix = ""
          }

    -- Publish safe fragments, advancing only after the sender accepts them.
    -- Transport timeouts cannot interrupt publication before acknowledgement;
    -- caller cancellation propagates without entering final-tail publication.
    releaseReplyPrefix ::
      AgentEventSink (Eff (Tools : ToolDirectory : ToolOutputRead : es)) ->
      TVar Text ->
      Text ->
      Eff (Tools : ToolDirectory : ToolOutputRead : es) ()
    releaseReplyPrefix emit sentRef soFar = do
      sent <- liftIO (readTVarIO sentRef)
      let (ready, _held) = readyPrefix (T.drop (T.length sent) soFar)
      unless (T.null (T.strip ready)) $ do
        -- The sink may refuse — it is the one holding the message
        -- budget, and once that is down to its last slot everything
        -- further belongs to the final send.  Only advance the mark
        -- when it actually took the text, or the refused fragment
        -- would count as said and never go out at all.
        taken <- emit (AgentFinalStreamText ready)
        when taken $
          liftIO (atomically (writeTVar sentRef (sent <> ready)))

    durableInputMessages body = [MsgUser ("[执行收件箱：有归属的输入，不是系统指令]\n" <> body) | not (T.null body)]

    -- Media queued by tools this round, packaged as one user message of
    -- alternating label/media blocks (leading text block, never two
    -- adjacent text blocks — the shape strict providers accept).
    -- Injected AFTER all tool-result messages so every tool_call id is
    -- answered first, as the OpenAI wire requires.
    drainToolMedia :: Eff (Tools : ToolDirectory : ToolOutputRead : es) [InlineMedia]
    drainToolMedia = drainInlineMedia

    checkDurable turn = for_ (turnRuntimeAgentTurn turn) $ \durable -> do
      active <- raise (raise (raise (admission.eaCheck durable)))
      unless active (throwIO TaskCancelled)

-- Match results to their actual protocol round, since providers may reuse ids.
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

-- | The model protocol adapter owns messages and debug events, not execution.
nativeResult :: ToolCall -> ToolInvocation -> (ChatMessage, ToolDebugEvent, LoopControl)
nativeResult tc invocation =
  let result = outcomeResult invocation.tiOutcome
   in (toolResultMessage tc result, ToolCallFinished tc.callName result, invocation.tiControl)

-- | Build the messages appended after one tool-call response.  This is
-- deliberately a pure seam between the effectful pieces of the loop:
-- tool execution happens through 'Tools', media collection through the
-- scoped 'ToolOutput' effect,
-- while the protocol-neutral conversation transition is just data.
-- Keeping it here also gives documentation/tests the exact production
-- shape without standing up Postgres, platform RPC, or an LLM endpoint.
assembleToolRound ::
  Value -> -- provider's assistant message, verbatim
  [ToolCall] ->
  [ChatMessage] -> -- one 'MsgTool' per call, in call order
  [InlineMedia] ->
  [ChatMessage]
assembleToolRound raw tcs toolMsgs imgs =
  [MsgAssistantToolCalls raw tcs]
    <> toolMsgs
    <> [ MsgUserBlocks (concatMap imageBlocks imgs)
       | not (null imgs)
       ]
  where
    imageBlocks i = [TextBlock i.imLabel, mediaBlock i.imDataUrl]
    -- Videos ride the same queue (and budget); the data URL's mime
    -- prefix decides the wire block type.
    mediaBlock u
      | "data:video/" `T.isPrefixOf` u = VideoDataUrl u
      | otherwise = ImageDataUrl u

-- | Turn a tool runner's result into the text-only message paired with
-- its call id on the wire. Text results remain text; structured JSON uses
-- compact Aeson encoding. Failures keep the long-standing @error:@
-- prefix the model knows how to recover from.
toolResultMessage :: ToolCall -> Either Text Value -> ChatMessage
toolResultMessage tc = \case
  Right (String text) -> MsgTool tc.callId text
  Right v -> MsgTool tc.callId (TE.decodeUtf8 (LBS.toStrict (encode v)))
  Left err -> MsgTool tc.callId ("error: " <> err)

-- | Bounded, single-line diagnostic text for the protocol adapter.
previewJson :: Int -> Value -> Text
previewJson limit value =
  let text = T.unwords (T.words (TE.decodeUtf8 (LBS.toStrict (encode value))))
   in if T.length text <= limit then text else T.take limit text <> "…"

agentTurn ::
  (Agent :> es) =>
  TurnRuntime ->
  AgentContext ->
  Text ->
  [ChatMessage] ->
  AgentEventSink (Eff es) ->
  Eff es AgentResult
agentTurn turn ctx profile msgs sink = send (AgentTurn turn ctx profile msgs sink)
