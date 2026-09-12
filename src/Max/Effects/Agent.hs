{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- The 'Agent' effect drives a multi-turn LLM loop with tool calls.
-- 'LLM' and 'Max.Effects.Tools.Tools' stay raw; this effect's
-- interpreter sits on top of both and discharges them locally so
-- callers of 'agentTurn' only need @Agent :> es@ in their constraints.
--
-- == Loop shape
--
-- Each iteration:
--
--   1. Drain pending feedback notes from the task's inbox; if any,
--      append a synthetic @MsgUser "[feedback]: …"@ before the next
--      chat call so the model sees the side-channel input immediately.
--   2. @chatStreaming(profile, msgs, specs, sink)@.  On a profile with
--      @stream: false@ this is an ordinary blocking call and the sink is
--      never used.
--   3. 'ContentResp' → return text.  'ToolCallsResp' → run each tool
--      via 'Tools', append assistant-with-tool-calls + tool-result
--      messages, re-enter.
--
-- After 'maxTurns' the loop stops with @aborted = Just AgentRoundLimit@
-- and a fallback reply.  Hard cap to keep cost bounded.
--
-- == Streaming
--
-- When the profile streams, the loop watches the text arrive and emits each
-- finished paragraph as an 'Max.AgentEvent.AgentFinalStreamText'.  It then
-- reports how much was accepted as 'sentPrefix' so the caller sends only the
-- rest.  The
-- bookkeeping resets per chat call, because one call is one utterance: a
-- progress narration, or the final answer.  Deciding /when/ a paragraph
-- is done belongs here; deciding how any event is rendered or delivered
-- belongs to the typed event sink — see 'AgentTurn'.
--
-- == Task lifecycle
--
-- 'Max.Handler' creates one 'Max.Tasks.TurnRuntime' when the dispatch is
-- admitted, before context collection.  'AgentTurn' receives that exact
-- object, installs the worker cancellation action, checks cancellation between
-- executable nodes, and drains its feedback inbox.  Handler remains the sole
-- lifecycle finalizer; no trigger-id lookup/adoption protocol sits between the
-- two layers.
--
-- == Per-group tools
--
-- The interpreter is parameterised by a @ToolContext -> [Tool es]@
-- factory.  When 'AgentTurn' fires, the factory produces the right
-- tool list for that turn; the interpreter spins up scoped 'ToolOutput'
-- and 'Tools' interpreters just for that call.
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
import Max.Execution.Workflow (WorkflowHost)
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
import Max.ModelCatalog (ModelCapabilities (..), defaultContextLimits, lookupModelCapabilities)
import Max.Reply (readyPrefix)
import Max.RuntimeConfig (RuntimeSnapshot (..), RuntimeValues (..))
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
import Max.ToolContext (ToolContext, TurnCapabilities (..), toolCapabilities, toolGroupId, toolRuntimeSnapshot, toolSkillLoads, toolTurnOutputContext, withToolInvocationIdentity, withToolSkillLoads)
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
      generation = (.rsGeneration) <$> toolRuntimeSnapshot ctx.acTools
   in ChatCtx (if (toolCapabilities ctx.acTools).tcBackground then "task/" <> source else source) (Just gid) ctx.acEffort Nothing Nothing durable generation

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
    -- | The leading slice of 'reply' that the streaming sink already
    -- sent, verbatim.  Empty for a non-streamed turn, which is every
    -- turn on a profile with @stream = false@.
    --
    -- The caller sends @T.drop (T.length sentPrefix) reply@.  Matching
    -- by /prefix/ rather than by chunk count is deliberate:
    -- 'Max.Reply.readyPrefix' guarantees the two halves concatenate
    -- back to the input and only ever cuts at a blank line, so the
    -- streamed prefix and the remainder split identically under
    -- 'Max.Reply.planReply'.  Counting chunks instead would rely on
    -- two code paths happening to agree.
    sentPrefix :: !Text
  }
  deriving stock (Show)

--------------------------------------------------------------------------------
-- Effect.

data Agent :: Effect where
  -- | Run a full agent loop for the given dispatch.  Returns when the
  -- model emits a content response, hits 'maxTurns', or the LLM errors.
  --
  -- The last argument is a typed event sink.  Progress narration, tool
  -- debug facts, and streamed final paragraphs are distinct constructors,
  -- so the output boundary can apply the right visibility, reply budget,
  -- rendering, and persistence policy without the loop importing any of
  -- those mechanisms.
  AgentTurn ::
    TurnRuntime ->
    AgentContext ->
    Text ->
    [ChatMessage] ->
    AgentEventSink m ->
    Agent m AgentResult

type instance DispatchOf Agent = Dynamic

-- | Install the agent loop on top of a stack that already has 'LLM'
-- (and 'Log', 'IOE').  Output leaves only through the typed event sink;
-- this interpreter has no platform, segment, or persistence dependency.
-- On each 'AgentTurn' it:
--
--   * Activates the explicit 'TurnRuntime' created by Handler.
--   * Spins up a 'Tools' scope built from the per-group factory.
--   * Drives the loop, draining the task's inbox between turns.
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
          (msgs'', eres) <- budgetedCall workingRef ctx h profile "turn" msgs' specs (Just (releaseParagraphs emit sentRef))
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
      let snapshot = toolRuntimeSnapshot ctx.acTools
          capabilities = snapshot >>= \snap -> lookupModelCapabilities profile snap.rsValues.rvModelCatalog
          limits = maybe defaultContextLimits (.contextLimits) capabilities
          identity = workingIdentity profile (T.pack (show ((.rsGeneration) <$> snapshot))) limits specs
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

    -- Hand the caller every paragraph that is safe to send, and
    -- remember how much of the text that accounted for.
    --
    -- Called with the assistant text /so far/, once per frame that
    -- extended it.  'readyPrefix' holds back the trailing paragraph
    -- (it may still grow) and refuses to cut inside a code fence, so
    -- most calls release nothing — and a single-paragraph reply, which
    -- is most replies, releases nothing at all.  That bound is the
    -- honest limit of what streaming buys here.
    --
    -- Transport timeouts run on the reader thread. They cannot interrupt this
    -- callback after publication but before its acknowledgement; cancellation
    -- of the caller propagates instead of entering the final-tail send path.
    releaseParagraphs ::
      AgentEventSink (Eff (Tools : ToolDirectory : ToolOutputRead : es)) ->
      TVar Text ->
      Text ->
      Eff (Tools : ToolDirectory : ToolOutputRead : es) ()
    releaseParagraphs emit sentRef soFar = do
      sent <- liftIO (readTVarIO sentRef)
      let (ready, _held) = readyPrefix (T.drop (T.length sent) soFar)
      unless (T.null (T.strip ready)) $ do
        -- The sink may refuse — it is the one holding the message
        -- budget, and once that is down to its last slot everything
        -- further belongs to the final send.  Only advance the mark
        -- when it actually took the text, or the refused paragraph
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
