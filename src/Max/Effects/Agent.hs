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
-- 'runAgent' takes a 'TaskRegistry'.  The registry entry already exists
-- — 'Max.Tasks.beginDispatch' opened it when the dispatch started, well
-- before this loop — so each 'AgentTurn' brackets an
-- 'Max.Tasks.attachTask' that adopts it, supplying the cancel action
-- @!kill@ needs and picking up a kill that arrived while the context
-- was still being built.  The same entry's inbox is what @!feedback@
-- and the supplement classifier push into.
--
-- == Per-group tools
--
-- The interpreter is parameterised by a @GroupId -> [Tool es]@
-- factory.  When 'AgentTurn' fires, the factory produces the right
-- tool list for that group; the interpreter spins up a 'Tools'
-- interpreter just for that call.
module Max.Effects.Agent
  ( Agent,
    AgentLimits (..),
    AgentResult (..),
    DispatchContext (..),
    ToolImage (..),
    queueToolImage,
    assembleToolRound,
    toolResultMessage,
    runAgent,
    agentTurn,
    defaultLimits,
  )
where

import Control.Concurrent (myThreadId, throwTo)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Monad (when)
import Data.Aeson (Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent.Async (Concurrent, mapConcurrently)
import Effectful.Dispatch.Dynamic (interpret, localSeqUnlift, send)
import Effectful.Exception (bracket, throwIO)
import Effectful.Log
import Max.AgentEvent (AgentEvent (..), AgentEventSink, ToolDebugEvent (..))
import Max.Effects.LLM (ChatCtx (..), ChatMessage (..), ChatResponse (..), ContentBlock (..), LLM, ToolCall (..), chat, chatStreaming)
import Max.Effects.Tools (Tool, Tools, invokeTool, listToolSpecs, runTools)
import Max.Reply (readyPrefix)
import Max.Tasks (Note (..), TaskCancelled (..), TaskHandle (..), TaskRegistry, attachTask, drainInbox, releaseTask, requeueInbox)
import OneBot.Types (GroupId (..), MessageId, UserId)

-- | Per-dispatch context the agent loop hands to its tool factory.
-- Tools like @say@ need the triggering message coordinates to thread
-- their reply correctly; ambient tools that only care about the group
-- can just project 'dcGroupId'.  'dcSelfId' is the bot's own QQ id,
-- needed by visible-output and reminder tools.
data DispatchContext = DispatchContext
  { dcGroupId :: !GroupId,
    dcMessageId :: !MessageId,
    dcUserId :: !UserId,
    dcSelfId :: !UserId,
    -- | Whether the active profile is multimodal.  The tool factory
    -- gates capability-heavy tools (e.g. the browser toolset) on this.
    dcMultimodal :: !Bool,
    -- | Effective sticker toggle for this dispatch (config default,
    -- possibly overridden per session via !sticker on/off).  The tool
    -- factory gates the send_sticker tool on this.
    dcStickers :: !Bool,
    -- | Whether this group has any skills visible (the system prompt
    -- then carries a 技能对照表).  The tool factory gates the
    -- use_skill tool on this — a group with no skills shouldn't pay
    -- schema tokens for a tool that could only fail.
    dcSkills :: !Bool,
    -- | The session's @!effort@ override, threaded into every LLM
    -- call this turn makes ('turnCtx').  'Nothing' = the profile's
    -- configured effort.
    dcEffort :: !(Maybe Text),
    -- | Images queued by tools (e.g. @view_avatar@) via
    -- 'queueToolImage' during the current tool round.  The loop drains
    -- the list after each round and injects them as a user-role
    -- image-blocks message — tool-result messages themselves are
    -- text-only on the OpenAI wire.  The counter tracks every image
    -- queued over the whole dispatch (it survives drains) so
    -- 'queueToolImage' can enforce 'maxToolImages'.
    dcToolImages :: !(TVar (Int, [ToolImage]))
  }

-- | One tool-queued inline image: a context label ("[avatar] Alice:")
-- plus a @data:<mime>;base64,...@ URL.
data ToolImage = ToolImage
  { tiLabel :: !Text,
    tiDataUrl :: !Text
  }

-- | Per-dispatch cap on tool-queued images — same order as the
-- prompt builder's own image budget; keeps a chatty model from
-- ballooning the context with base64.
maxToolImages :: Int
maxToolImages = 8

-- | Queue an image for injection after the current tool round.
-- 'False' when the dispatch's image budget is already spent (the
-- tool should surface that as its error text).
-- | Usage attribution for a dispatch's own LLM calls.  Private chats
-- report their pseudo-group id — that is the conversation the spend
-- belongs to.
turnCtx :: DispatchContext -> Text -> ChatCtx
turnCtx dc source = let GroupId g = dc.dcGroupId in ChatCtx source (Just g) dc.dcEffort

queueToolImage :: (IOE :> es) => DispatchContext -> ToolImage -> Eff es Bool
queueToolImage dc img = liftIO . atomically $ do
  (n, imgs) <- readTVar dc.dcToolImages
  if n >= maxToolImages
    then pure False
    else True <$ writeTVar dc.dcToolImages (n + 1, imgs <> [img])

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
    DispatchContext ->
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
--   * Registers a task in the 'TaskRegistry' (and unregisters via
--     'bracket' on exit, including 'TaskCancelled' from @!kill@).
--   * Spins up a 'Tools' scope built from the per-group factory.
--   * Drives the loop, draining the task's inbox between turns.
runAgent ::
  forall es a.
  (LLM :> es, Concurrent :> es, Log :> es, IOE :> es) =>
  AgentLimits ->
  (DispatchContext -> [Tool es]) ->
  TaskRegistry ->
  Eff (Agent : es) a ->
  Eff es a
runAgent lims toolFactory taskReg = interpret $ \localEnv -> \case
  AgentTurn dc profile msgs sink -> localSeqUnlift localEnv $ \unlift -> do
    selfTid <- liftIO myThreadId
    let cancel = throwTo selfTid TaskCancelled
        emit :: AgentEventSink (Eff (Tools : es))
        emit event = raise (unlift (sink event))
    bracket
      (liftIO (attachTask taskReg dc.dcGroupId dc.dcUserId (Just dc.dcMessageId) "llm" cancel))
      (liftIO . releaseTask taskReg)
      ( \handle -> do
          -- A !kill that landed while the dispatch was still building
          -- its context has no thread to interrupt yet; the registry
          -- held it for us.  Honour it before spending a turn.
          when handle.thPreKilled $ throwIO TaskCancelled
          runTools (toolFactory dc) (loop emit dc handle profile msgs)
      )
  where
    loop ::
      AgentEventSink (Eff (Tools : es)) ->
      DispatchContext ->
      TaskHandle ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : es) AgentResult
    loop emit dc h profile = go emit dc h 0 [] profile

    go ::
      AgentEventSink (Eff (Tools : es)) ->
      DispatchContext ->
      TaskHandle ->
      Int ->
      [ChatMessage] ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : es) AgentResult
    go emit dc h n appended profile msgs = do
      -- Drain any feedback notes that arrived since the previous turn.
      notes <- liftIO (drainInbox h)
      let (msgs', appended') = case notes of
            [] -> (msgs, appended)
            xs -> (msgs <> [feedbackMsg xs], appended <> [feedbackMsg xs])
      if n >= lims.maxTurns
        then finalAnswer dc n appended' profile msgs'
        else do
          specs <- listToolSpecs
          -- Trim before the call AND carry the trimmed list forward
          -- (every recursion below builds on msgs''): stubs are
          -- permanent, so between trim events the list is byte-stable
          -- and the provider's prefix cache survives.
          let msgs'' = capToolResults toolResultBudget msgs'
          -- Reset per call: one chat call is one utterance (a progress
          -- narration, or the final answer), and each gets its own
          -- prefix bookkeeping.
          sentRef <- liftIO (newTVarIO "")
          eres <- chatStreaming (turnCtx dc "turn") profile msgs'' specs (releaseParagraphs emit sentRef)
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
              lateNotes <- liftIO (drainInbox h)
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
                      liftIO (requeueInbox h xs)
                      logInfo "agent: feedback raced a streamed answer, returned to inbox" $
                        object ["count" .= length xs, "sent_chars" .= T.length sent]
                      done
                  | otherwise -> do
                      logInfo "agent: btw notes raced final answer, continuing" $
                        object ["count" .= length xs]
                      let newMsgs = [MsgAssistant text, feedbackMsg xs]
                      go emit dc h (n + 1) (appended' <> newMsgs) profile (msgs'' <> newMsgs)
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
              emit (AgentProgressText (T.drop (T.length sent) narration))
              emit $
                AgentToolDebug $
                  ToolCallsStarted [(tc.callName, tc.callArguments) | tc <- tcs]
              -- Carry the provider's message verbatim so its thinking
              -- output round-trips back to the API on the next
              -- request — DeepSeek returns 400 otherwise.
              -- Independent calls in one round run concurrently (DB
              -- goes through the pool, image attachment through STM);
              -- results keep call order so each tool_call id is
              -- answered in sequence.
              executed <- case tcs of
                [tc] -> (: []) <$> executeOne tc
                _ -> mapConcurrently executeOne tcs
              -- Emit result facts after the concurrent round rejoins.  This
              -- keeps the higher-rank callback on its sequential unlift and
              -- gives debug output a deterministic call order.
              for_ executed $ \(_, event) -> emit (AgentToolDebug event)
              let toolMsgs = map fst executed
              imgs <- drainToolImages dc
              let newMsgs = assembleToolRound raw tcs toolMsgs imgs
              go emit dc h (n + 1) (appended' <> newMsgs) profile (msgs'' <> newMsgs)

    -- Hit the turn cap: make one final tool-free chat call so the user
    -- gets a real answer built from whatever the loop already gathered,
    -- rather than a bare "max turns" error.  Empty tool specs force a
    -- content response; a synthetic note tells the model to wrap up.
    finalAnswer ::
      DispatchContext ->
      Int ->
      [ChatMessage] ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : es) AgentResult
    finalAnswer dc n appended profile msgs = do
      logInfo "agent: max turns reached, forcing final answer" $
        object ["turns" .= n]
      let capNote =
            MsgUser
              "[system] 工具调用轮次已用满，别再调用任何工具了。\
              \直接根据目前已经掌握的信息，给用户一个最终回复。"
      eres <-
        chat (turnCtx dc "wrapup") profile (capToolResults toolResultBudget (msgs <> [capNote])) []
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
      AgentEventSink (Eff (Tools : es)) ->
      TVar Text ->
      Text ->
      Eff (Tools : es) ()
    releaseParagraphs emit sentRef soFar = do
      sent <- liftIO (readTVarIO sentRef)
      let (ready, _held) = readyPrefix (T.drop (T.length sent) soFar)
      when (not (T.null (T.strip ready))) $ do
        -- The sink may refuse — it is the one holding the message
        -- budget, and once that is down to its last slot everything
        -- further belongs to the final send.  Only advance the mark
        -- when it actually took the text, or the refused paragraph
        -- would count as said and never go out at all.
        taken <- emit (AgentFinalStreamText ready)
        when taken $
          liftIO (atomically (writeTVar sentRef (sent <> ready)))

    -- Notes that arrived mid-turn, from !feedback or from a message the
    -- classifier read as steering.  Marked so the model can tell them
    -- from the original request without being told twice.
    feedbackMsg :: [Note] -> ChatMessage
    feedbackMsg xs = MsgUser ("[feedback]: " <> T.intercalate " | " (map (.noteLine) xs))

    -- Images tools queued this round, packaged as one user message of
    -- alternating label/image blocks (leading text block, never two
    -- adjacent text blocks — the shape strict providers accept).
    -- Injected AFTER all tool-result messages so every tool_call id is
    -- answered first, as the OpenAI wire requires.
    drainToolImages :: DispatchContext -> Eff (Tools : es) [ToolImage]
    drainToolImages dc = do
      liftIO . atomically $ do
        (n, is) <- readTVar dc.dcToolImages
        writeTVar dc.dcToolImages (n, [])
        pure is

    executeOne :: ToolCall -> Eff (Tools : es) (ChatMessage, ToolDebugEvent)
    executeOne tc = do
      logInfo "agent: tool call" $
        object
          [ "id" .= tc.callId,
            "name" .= tc.callName,
            "args" .= previewJson 200 tc.callArguments
          ]
      result <- invokeTool tc.callName tc.callArguments
      case result of
        Right v -> do
          let full = TE.decodeUtf8 (LBS.toStrict (encode v))
          logInfo "agent: tool result" $
            object
              [ "id" .= tc.callId,
                "name" .= tc.callName,
                "result" .= previewJson 400 v,
                "full_len" .= T.length full
              ]
          pure (toolResultMessage tc (Right v), ToolCallFinished tc.callName (Right v))
        Left err -> do
          logAttention "agent: tool failed" $
            object ["id" .= tc.callId, "name" .= tc.callName, "error" .= err]
          pure (toolResultMessage tc (Left err), ToolCallFinished tc.callName (Left err))

-- | Build the messages appended after one tool-call response.  This is
-- deliberately a pure seam between the effectful pieces of the loop:
-- tool execution happens through 'Tools', image collection through STM,
-- while the protocol-neutral conversation transition is just data.
-- Keeping it here also gives documentation/tests the exact production
-- shape without standing up Postgres, NapCat, or an LLM endpoint.
assembleToolRound ::
  Value -> -- provider's assistant message, verbatim
  [ToolCall] ->
  [ChatMessage] -> -- one 'MsgTool' per call, in call order
  [ToolImage] ->
  [ChatMessage]
assembleToolRound raw tcs toolMsgs imgs =
  [MsgAssistantToolCalls raw tcs]
    <> toolMsgs
    <> [ MsgUserBlocks (concatMap imageBlocks imgs)
       | not (null imgs)
       ]
  where
    imageBlocks i = [TextBlock i.tiLabel, mediaBlock i.tiDataUrl]
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
  DispatchContext ->
  Text ->
  [ChatMessage] ->
  AgentEventSink (Eff es) ->
  Eff es AgentResult
agentTurn dc profile msgs sink = send (AgentTurn dc profile msgs sink)
