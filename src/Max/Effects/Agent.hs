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
-- After 'maxTurns' the loop stops with @aborted = Just "max-turns"@
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
    runAgent,
    runDurableAgent,
    agentTurn,
    defaultLimits,
  )
where

import Control.Concurrent (myThreadId, throwTo)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (unless, when)
import Data.Aeson (Value (..), encode, toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.List (find)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent.Async (Concurrent, mapConcurrently)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift, send)
import Effectful.Exception (SomeException, catch, throwIO)
import Effectful.Log
import Max.AgentEvent (AgentEvent (..), AgentEventSink, ToolDebugEvent (..))
import Max.DB.AgentTurn
  ( JournalExecution,
    JournalFinish (..),
    JournalStart (..),
    enrichSandboxJournalStart,
    finishJournalExecution,
    markJournalOutcomeUnknown,
    recordModelNote,
    recordAgentTurnLlmRound,
    startJournalExecution,
  )
import Max.Effects.Blob (Blob)
import Max.Effects.LLM (ChatCtx (..), ChatMessage (..), ChatResponse (..), ContentBlock (..), LLM, ToolCall (..), chat, chatStreaming)
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, defaultInlineMediaLimit, drainInlineMedia, runToolOutput)
import Max.Effects.Tools
  ( CatalogTool (..),
    ToolCatalog,
    ToolCatalogError,
    ToolDefinition (..),
    ToolEffect (..),
    ToolFault (..),
    ToolOutcome (..),
    ToolParallelism (..),
    ToolRef (..),
    ToolRetryClass (..),
    SchemaHash (..),
    SchemaVersion (..),
    Tools,
    invokeTool,
    listCatalogTools,
    listToolSpecs,
    outcomeResult,
    runTools,
  )
import Max.Reply (readyPrefix)
import Max.Tasks
  ( Note (..),
    NoteVerb (..),
    TaskCancelled (..),
    TurnRuntime,
    activateTurnRuntime,
    checkTurnCancellation,
    drainTurnInbox,
    requeueTurnInbox,
    setTurnPhase,
    turnRuntimeAgentTurn,
  )
import Max.ToolContext (ToolContext, toolGroupId, toolTurnOutputContext)
import Max.Turn.Types (AgentTurnRef (..), turnOutputAgentTurn)
import Effectful.PostgreSQL (WithConnection)
import OneBot.Types (GroupId (..))

-- | Agent-only data around the neutral context handed to tools.
data AgentContext = AgentContext
  { acTools :: !ToolContext,
    -- | The session's @!effort@ override, threaded into every LLM
    -- call this turn makes ('turnCtx').  'Nothing' = the profile's
    -- configured effort.
    acEffort :: !(Maybe Text),
    -- | Host-enforced tool-call budget for a delegated child. Ordinary turns
    -- use 'Nothing'. Administrative return/guide calls are free; a child
    -- plan_run conservatively reserves its whole call budget, so direct calls
    -- and an inner plan cannot each spend the same allowance.
    acMaxToolCalls :: !(Maybe Int)
  }

-- | Usage attribution for a dispatch's own LLM calls.  Private chats
-- report their pseudo-group id — that is the conversation the spend
-- belongs to.
turnCtx :: AgentContext -> Text -> ChatCtx
turnCtx ctx source =
  let GroupId gid = toolGroupId ctx.acTools
      durable = (.atrTurnId) . turnOutputAgentTurn <$> toolTurnOutputContext ctx.acTools
   in ChatCtx source (Just gid) ctx.acEffort Nothing Nothing durable

-- | Caps on a single agent invocation.  Per-tool and per-call HTTP
-- timeouts are configured at the 'LLM' layer; these are loop-level.
data AgentLimits = AgentLimits
  { -- | Maximum number of LLM round-trips per dispatch.  Counts each
    -- 'chat' call, whether it returned content or tool calls.
    maxTurns :: !Int
  }
  deriving stock (Show)

-- | Sane starting point: 200 turns covers long multi-round sandbox
-- sessions with @say@ status updates interleaved, while still capping
-- runaway loops.  Hard cap to keep cost bounded.
defaultLimits :: AgentLimits
defaultLimits = AgentLimits {maxTurns = 200}

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
    aborted :: !(Maybe Text),
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
runAgent ::
  forall es a.
  (LLM :> es, Concurrent :> es, Log :> es, IOE :> es) =>
  AgentLimits ->
  (ToolContext -> Either ToolCatalogError (ToolCatalog (ToolOutput : es))) ->
  Eff (Agent : es) a ->
  Eff es a
runAgent lims toolFactory = runAgentWithJournal noAgentJournal lims toolFactory

-- | Production interpreter.  Keeping the journal callbacks outside the
-- generic loop preserves the existing in-memory Agent seam while ensuring the
-- real stack always writes E0 rows.
runDurableAgent ::
  forall es a.
  ( LLM :> es,
    Concurrent :> es,
    Blob :> es,
    WithConnection :> es,
    Log :> es,
    IOE :> es
  ) =>
  AgentLimits ->
  (ToolContext -> Either ToolCatalogError (ToolCatalog (ToolOutput : es))) ->
  Eff (Agent : es) a ->
  Eff es a
runDurableAgent = runAgentWithJournal durableAgentJournal

data AgentJournal es = AgentJournal
  { ajRecordLlmRound :: AgentTurnRef -> Eff es Bool,
    ajRecordNote :: AgentTurnRef -> Text -> Eff es (),
    ajStart :: GroupId -> AgentTurnRef -> JournalStart -> Eff es (Maybe JournalExecution),
    ajFinish :: JournalExecution -> JournalFinish -> Eff es (),
    ajUnknown :: JournalExecution -> Text -> Eff es ()
  }

noAgentJournal :: AgentJournal es
noAgentJournal =
  AgentJournal
    { ajRecordLlmRound = \_ -> pure True,
      ajRecordNote = \_ _ -> pure (),
      ajStart = \_ _ _ -> pure Nothing,
      ajFinish = \_ _ -> pure (),
      ajUnknown = \_ _ -> pure ()
    }

durableAgentJournal ::
  (Blob :> es, WithConnection :> es, IOE :> es) =>
  AgentJournal es
durableAgentJournal =
  AgentJournal
    { ajRecordLlmRound = recordAgentTurnLlmRound . (.atrTurnId),
      ajRecordNote = recordModelNote,
      ajStart = \gid turn start -> do
        enriched <- enrichSandboxJournalStart gid start
        Just <$> startJournalExecution turn enriched,
      ajFinish = finishJournalExecution,
      ajUnknown = markJournalOutcomeUnknown
    }

runAgentWithJournal ::
  forall es a.
  (LLM :> es, Concurrent :> es, Log :> es, IOE :> es) =>
  AgentJournal es ->
  AgentLimits ->
  (ToolContext -> Either ToolCatalogError (ToolCatalog (ToolOutput : es))) ->
  Eff (Agent : es) a ->
  Eff es a
runAgentWithJournal journal lims toolFactory = interpret $ \localEnv -> \case
  AgentTurn turn ctx profile msgs sink -> localSeqUnlift localEnv $ \unlift -> do
    selfTid <- liftIO myThreadId
    catalog <- either throwIO pure (toolFactory ctx.acTools)
    let cancel = throwTo selfTid TaskCancelled
        emit :: AgentEventSink (Eff (Tools : ToolOutput : es))
        emit event = raise (raise (unlift (sink event)))
    -- Handler created this runtime before context collection and remains its
    -- sole finalizer.  Agent only activates the worker cancellation hook and
    -- consumes feedback through the explicit object.
    preKilled <- liftIO (activateTurnRuntime turn "llm" cancel)
    when preKilled $ throwIO TaskCancelled
    runToolOutput defaultInlineMediaLimit $
      runTools catalog (loop emit ctx turn profile msgs)
  where
    loop ::
      AgentEventSink (Eff (Tools : ToolOutput : es)) ->
      AgentContext ->
      TurnRuntime ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : ToolOutput : es) AgentResult
    loop emit ctx h profile = go emit ctx h 0 0 [] profile

    go ::
      AgentEventSink (Eff (Tools : ToolOutput : es)) ->
      AgentContext ->
      TurnRuntime ->
      Int ->
      Int ->
      [ChatMessage] ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : ToolOutput : es) AgentResult
    go emit ctx h n callsUsed appended profile msgs = do
      -- Drain any feedback notes that arrived since the previous turn.
      liftIO (checkTurnCancellation h)
      notes <- liftIO (drainTurnInbox h)
      let (msgs', appended') = case notes of
            [] -> (msgs, appended)
            xs -> (msgs <> [feedbackMsg xs], appended <> [feedbackMsg xs])
      if n >= lims.maxTurns
        then finalAnswer ctx h n appended' profile msgs'
        else do
          liftIO (setTurnPhase h "llm")
          specs <- listToolSpecs
          -- Trim before the call AND carry the trimmed list forward
          -- (every recursion below builds on msgs''): stubs are
          -- permanent, so between trim events the list is byte-stable
          -- and the provider's prefix cache survives.
          let msgs'' = capToolResults toolResultBudget msgs'
          -- Reset per call: one chat call is one utterance (a progress
          -- narration, or the final answer), and each gets its own
          -- prefix bookkeeping.
          for_ (turnRuntimeAgentTurn h) $ \durable ->
            do
              active <- raise (raise (journal.ajRecordLlmRound durable))
              unless active (throwIO TaskCancelled)
          sentRef <- liftIO (newTVarIO "")
          eres <- chatStreaming (turnCtx ctx "turn") profile msgs'' specs (releaseParagraphs emit sentRef)
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
            Right (ContentResp text) -> do
              -- A feedback note that raced in during this final call
              -- would be lost — the task is released right after we
              -- return, and the reply it was meant to steer is already
              -- written.  If any arrived, loop instead: the unsent draft
              -- stays in the conversation and the model re-answers with
              -- the note in view.
              lateNotes <- liftIO (drainTurnInbox h)
              let done =
                    pure
                      AgentResult
                        { reply = Just text,
                          appended = appended' <> [MsgAssistant text],
                          turnsUsed = n + 1,
                          aborted = Nothing,
                          sentPrefix = sent
                        }
              case lateNotes of
                [] -> done
                xs
                  -- Re-answering is only free while nothing has been
                  -- said.  Once streaming has put part of this draft in
                  -- the group, looping would leave half an abandoned
                  -- answer standing above its replacement — so the notes
                  -- go back to the inbox instead: a note leaves it only
                  -- by entering the conversation, and what stays behind
                  -- surfaces at 'Max.Tasks.endDispatch' for the dispatch
                  -- epilogue to re-dispatch or formally drop.
                  | not (T.null sent) -> do
                      liftIO (requeueTurnInbox h xs)
                      logInfo "agent: feedback raced a streamed answer, returned to inbox" $
                        object ["count" .= length xs, "sent_chars" .= T.length sent]
                      done
                  | otherwise -> do
                      logInfo "agent: btw notes raced final answer, continuing" $
                        object ["count" .= length xs]
                      let newMsgs = [MsgAssistant text, feedbackMsg xs]
                      go emit ctx h (n + 1) callsUsed (appended' <> newMsgs) profile (msgs'' <> newMsgs)
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
                raise (raise (journal.ajRecordNote durable narration))
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
              let returnRound = any ((== "subgoal_return") . (.callName)) tcs
                  suppressed tc = returnRound && tc.callName /= "subgoal_return"
                  remaining = maybe maxBound (\limit -> max 0 (limit - callsUsed)) ctx.acMaxToolCalls
                  callCost tc
                    | tc.callName `elem` ["subgoal_return", "plan_guide"] = 0
                    | tc.callName == "plan_run" = maybe 1 (max 1) ctx.acMaxToolCalls
                    | otherwise = 1
                  roundCost = sum [callCost tc | tc <- tcs, not (suppressed tc)]
                  overBudget = roundCost > remaining
              journalRows <-
                if overBudget
                  then pure (replicate (length tcs) Nothing)
                  else
                    traverse
                      (\tc -> if suppressed tc then pure Nothing else prepareJournal (toolGroupId ctx.acTools) h registered tc)
                      tcs
              let canParallel tc =
                    any
                      (\view ->
                         view.ctDefinition.tdRef == ToolRef tc.callName
                           && view.ctDefinition.tdParallelism == ParallelSafe
                      )
                      registered
              let journaledCalls = zip tcs journalRows
              executed <-
                if overBudget
                  then
                    pure
                      [ ( toolResultMessage tc (Left "这个子任务的工具调用额度已经用满，不能再执行这个调用"),
                          ToolCallFinished tc.callName (Left "child tool-call budget exhausted")
                        )
                      | tc <- tcs
                      ]
                  else case journaledCalls of
                    [call] -> (: []) <$> executeOne h call
                    _
                      | returnRound ->
                          traverse
                            (\call@(tc, _) ->
                               if suppressed tc
                                 then
                                   pure
                                     ( toolResultMessage tc (Left "subgoal_return 必须单独提交；同一轮的其他工具调用已拒绝"),
                                       ToolCallFinished tc.callName (Left "tool suppressed after child return")
                                     )
                                 else executeOne h call
                            )
                            journaledCalls
                    _
                      | all canParallel tcs -> mapConcurrently (executeOne h) journaledCalls
                      | otherwise -> traverse (executeOne h) journaledCalls
              -- Emit result facts after the concurrent round rejoins.  This
              -- keeps the higher-rank callback on its sequential unlift and
              -- gives debug output a deterministic call order.
              for_ executed $ \(_, event) -> emit (AgentToolDebug event)
              let toolMsgs = map fst executed
              imgs <- drainToolMedia
              let newMsgs = assembleToolRound raw tcs toolMsgs imgs
                  returned =
                    or
                      [ tc.callName == "subgoal_return" && not ("error:" `T.isPrefixOf` content)
                      | (tc, MsgTool _ content) <- zip tcs toolMsgs
                      ]
              if returned
                then
                  pure
                    AgentResult
                      { reply = Nothing,
                        appended = appended' <> newMsgs,
                        turnsUsed = n + 1,
                        aborted = Nothing,
                        sentPrefix = sent
                      }
                else
                  go emit ctx h (n + 1) (callsUsed + if overBudget then 0 else roundCost) (appended' <> newMsgs) profile (msgs'' <> newMsgs)

    -- Hit the turn cap: make one final tool-free chat call so the user
    -- gets a real answer built from whatever the loop already gathered,
    -- rather than a bare "max turns" error.  Empty tool specs force a
    -- content response; a synthetic note tells the model to wrap up.
    finalAnswer ::
      AgentContext ->
      TurnRuntime ->
      Int ->
      [ChatMessage] ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : ToolOutput : es) AgentResult
    finalAnswer ctx h n appended profile msgs = do
      logInfo "agent: max turns reached, forcing final answer" $
        object ["turns" .= n]
      liftIO (checkTurnCancellation h)
      for_ (turnRuntimeAgentTurn h) $ \durable -> do
        active <- raise (raise (journal.ajRecordLlmRound durable))
        unless active (throwIO TaskCancelled)
      let capNote =
            MsgUser
              "[system] 工具调用轮次已用满，别再调用任何工具了。\
              \直接根据目前已经掌握的信息，给用户一个最终回复。"
      eres <-
        chat (turnCtx ctx "wrapup") profile (capToolResults toolResultBudget (msgs <> [capNote])) []
      let (mText, ab) = case eres of
            Right (ContentResp t) | not (T.null (T.strip t)) -> (Just t, Just "max-turns")
            Right _ -> (Nothing, Just "max-turns")
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
    -- The TVar is written before the send, not after: if sending throws
    -- we have still said that much, and re-releasing the same paragraph
    -- on the next frame would say it twice.
    releaseParagraphs ::
      AgentEventSink (Eff (Tools : ToolOutput : es)) ->
      TVar Text ->
      Text ->
      Eff (Tools : ToolOutput : es) ()
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

    -- Whatever was said while this turn was working.  Two labels, and they
    -- report provenance rather than meaning: [feedback] is a claim its speaker
    -- made — they typed the verb, or replied to this turn's own output —
    -- whereas the other says only that a line arrived after work started.
    --
    -- Nothing upstream reads either one for intent any more (ADR 007 §8), so
    -- the labels must not pretend to: a single [feedback] tag over everything
    -- told the model that 明天我休假 was an instruction, and that was a
    -- classifier's guess wearing a tag's authority.
    feedbackMsg :: [Note] -> ChatMessage
    feedbackMsg xs =
      MsgUser . T.intercalate "\n" $
        [ label <> T.intercalate " | " (map (.noteLine) group)
          | (verb, label) <-
              [ (NoteSteer, "[feedback]: "),
                (NoteAmbient, "[群里新消息]（你开始做事之后进来的）: ")
              ],
            let group = filter ((== verb) . (.noteVerb)) xs,
            not (null group)
        ]

    -- Media queued by tools this round, packaged as one user message of
    -- alternating label/media blocks (leading text block, never two
    -- adjacent text blocks — the shape strict providers accept).
    -- Injected AFTER all tool-result messages so every tool_call id is
    -- answered first, as the OpenAI wire requires.
    drainToolMedia :: Eff (Tools : ToolOutput : es) [InlineMedia]
    drainToolMedia = drainInlineMedia

    prepareJournal ::
      GroupId ->
      TurnRuntime ->
      [CatalogTool] ->
      ToolCall ->
      Eff (Tools : ToolOutput : es) (Maybe JournalExecution)
    prepareJournal gid turn registered tc = case turnRuntimeAgentTurn turn of
      Nothing -> pure Nothing
      Just durable -> do
        let mView = find ((== ToolRef tc.callName) . (.ctDefinition.tdRef)) registered
            start = maybe (unknownJournalStart tc) (catalogJournalStart tc) mView
        raise (raise (journal.ajStart gid durable start))

    executeOne :: TurnRuntime -> (ToolCall, Maybe JournalExecution) -> Eff (Tools : ToolOutput : es) (ChatMessage, ToolDebugEvent)
    executeOne turn (tc, journalRow) = do
      liftIO (checkTurnCancellation turn)
      logInfo "agent: tool call" $
        object
          [ "id" .= tc.callId,
            "name" .= tc.callName,
            "args" .= previewJson 200 tc.callArguments
          ]
      outcome <-
        invokeTool tc.callName tc.callArguments
          `catch` \e -> do
            for_ journalRow $ \row ->
              raise (raise (journal.ajUnknown row (T.pack (show (e :: SomeException)))))
            throwIO e
      for_ journalRow $ \row ->
        raise (raise (journal.ajFinish row (journalFinish outcome)))
      liftIO (checkTurnCancellation turn)
      -- Host-only observation fields are journal evidence.  Remove them from
      -- the value returned to the model so E0 changes durability without
      -- changing the tool protocol or influencing the answer.
      let result = outcomeResult (stripJournalMetadata outcome)
      case result of
        Right v -> do
          let full = TE.decodeUtf8 (LBS.toStrict (encode v))
          logInfo "agent: tool result" $
            object
              [ "id" .= tc.callId,
                "name" .= tc.callName,
                "outcome" .= outcomeName outcome,
                "result" .= previewJson 400 v,
                "full_len" .= T.length full
              ]
          pure (toolResultMessage tc (Right v), ToolCallFinished tc.callName (Right v))
        Left err -> do
          logAttention "agent: tool failed" $
            object ["id" .= tc.callId, "name" .= tc.callName, "outcome" .= outcomeName outcome, "error" .= err]
          pure (toolResultMessage tc (Left err), ToolCallFinished tc.callName (Left err))

    outcomeName :: ToolOutcome -> Text
    outcomeName = \case
      ToolRejected {} -> "rejected"
      ToolFailedBeforeEffect {} -> "failed-before-effect"
      ToolSucceeded {} -> "succeeded"
      ToolCommitted {} -> "committed"
      ToolOutcomeUnknown {} -> "outcome-unknown"

    catalogJournalStart :: ToolCall -> CatalogTool -> JournalStart
    catalogJournalStart tc view =
      JournalStart
        { jsCallId = tc.callId,
          jsToolRef = tc.callName,
          jsSchemaVersion = view.ctDefinition.tdSchemaVersion.unSchemaVersion,
          jsSchemaHash = view.ctSchemaHash.unSchemaHash,
          jsInput = tc.callArguments,
          jsEffectLabels = toJSON (map effectLabel (Set.toList view.ctDefinition.tdEffects)),
          jsRetryClass = retryClassText view.ctDefinition.tdRetryClass
        }

    unknownJournalStart :: ToolCall -> JournalStart
    unknownJournalStart tc =
      JournalStart tc.callId tc.callName 0 "unknown" tc.callArguments (toJSON ([] :: [Value])) "safe"

    effectLabel :: ToolEffect -> Value
    effectLabel = \case
      EffectRead domain -> object ["kind" .= ("read" :: Text), "domain" .= domain]
      EffectWrite domain -> object ["kind" .= ("write" :: Text), "domain" .= domain]
      EffectSend domain -> object ["kind" .= ("send" :: Text), "domain" .= domain]
      EffectLLM -> object ["kind" .= ("llm" :: Text)]
      EffectReflect -> object ["kind" .= ("reflect" :: Text)]

    retryClassText :: ToolRetryClass -> Text
    retryClassText = \case
      RetrySafe -> "safe"
      RetryIdempotent -> "idempotent"
      RetryUnsafe -> "unsafe"

    journalFinish :: ToolOutcome -> JournalFinish
    journalFinish = \case
      ToolRejected fault -> JournalRejected fault.tfCode fault.tfMessage
      ToolFailedBeforeEffect fault -> JournalFailed fault.tfCode fault.tfMessage
      ToolSucceeded value -> JournalSucceeded value
      ToolCommitted value -> JournalCommitted value
      ToolOutcomeUnknown fault -> JournalOutcomeUnknown fault.tfCode fault.tfMessage

    stripJournalMetadata :: ToolOutcome -> ToolOutcome
    stripJournalMetadata = \case
      ToolSucceeded value -> ToolSucceeded (stripValue value)
      ToolCommitted value -> ToolCommitted (stripValue value)
      other -> other
      where
        stripValue (Object fields) =
          Object
            ( KeyMap.delete "_max_journal_canonical_message_id" $
                KeyMap.delete "_max_journal_observed_manifest" fields
            )
        stripValue value = value

-- | Build the messages appended after one tool-call response.  This is
-- deliberately a pure seam between the effectful pieces of the loop:
-- tool execution happens through 'Tools', media collection through the
-- scoped 'ToolOutput' effect,
-- while the protocol-neutral conversation transition is just data.
-- Keeping it here also gives documentation/tests the exact production
-- shape without standing up Postgres, PlatformApi, or an LLM endpoint.
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
-- its call id on the wire.  Successful JSON uses the same compact Aeson
-- encoding as the live loop; failures keep the long-standing @error:@
-- prefix the model knows how to recover from.
toolResultMessage :: ToolCall -> Either Text Value -> ChatMessage
toolResultMessage tc = \case
  Right v -> MsgTool tc.callId (TE.decodeUtf8 (LBS.toStrict (encode v)))
  Left err -> MsgTool tc.callId ("error: " <> err)

-- | Render a 'Value' as a single-line preview suitable for logs:
-- newlines/whitespace collapsed, truncated to @n@ characters with an
-- ellipsis suffix.  Keeps log lines readable without losing context.
previewJson :: Int -> Value -> Text
previewJson n v =
  let s = TE.decodeUtf8 (LBS.toStrict (encode v))
      collapsed = T.unwords (T.words s)
   in if T.length collapsed <= n
        then collapsed
        else T.take n collapsed <> "…"

-- | High watermark: total tool-result characters tolerated before a
-- trim event.  Individual tools already cap their own output
-- (~16 KiB), but a long multi-round sandbox loop can still stack
-- dozens of those; this bounds the whole conversation.
toolResultBudget :: Int
toolResultBudget = 60000

-- | Cap the combined size of tool-result content sent to the model.
-- Two-watermark hysteresis: nothing is touched until the total
-- passes @budget@; then older results are stubbed until the intact
-- survivors fit in half of it.  The caller carries the trimmed list
-- forward, so between (rare) trim events the message list — and with
-- it the provider's prefix cache — stays byte-stable.  The previous
-- per-request sliding boundary re-stubbed one more old result nearly
-- every turn once over budget, invalidating the cache from that
-- point on every call.  Every 'MsgTool' is preserved (dropping one
-- would orphan its assistant @tool_call@ and make the request
-- invalid), and an already-stubbed result is never rewritten.
capToolResults :: Int -> [ChatMessage] -> [ChatMessage]
capToolResults budget msgs
  | total <= budget = msgs
  | otherwise = reverse (go (budget `div` 2) (reverse msgs))
  where
    total = sum [T.length c | MsgTool _ c <- msgs]
    go _ [] = []
    go rem_ (m : rest) = case m of
      MsgTool cid content
        | isStub content -> m : go rem_ rest
        | rem_ <= 0 -> MsgTool cid (stub content) : go 0 rest
        | otherwise ->
            let len = T.length content
             in if len <= rem_
                  then m : go (rem_ - len) rest
                  else MsgTool cid (stub content) : go 0 rest
      _ -> m : go rem_ rest
    isStub = (elision `T.isSuffixOf`)
    stub content = T.take 300 content <> elision
    elision = "\n…[older tool results truncated]"

agentTurn ::
  (Agent :> es) =>
  TurnRuntime ->
  AgentContext ->
  Text ->
  [ChatMessage] ->
  AgentEventSink (Eff es) ->
  Eff es AgentResult
agentTurn turn ctx profile msgs sink = send (AgentTurn turn ctx profile msgs sink)
