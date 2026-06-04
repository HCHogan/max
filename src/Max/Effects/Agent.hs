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
--   1. Drain pending @!btw@ notes from the task's inbox; if any,
--      append a synthetic @MsgUser "[侧记]: …"@ before the next chat
--      call so the model sees the side-channel input immediately.
--   2. @chat(profile, msgs, specs)@.
--   3. 'ContentResp' → return text.  'ToolCallsResp' → run each tool
--      via 'Tools', append assistant-with-tool-calls + tool-result
--      messages, re-enter.
--
-- After 'maxTurns' the loop stops with @aborted = Just "max-turns"@
-- and a fallback reply.  Hard cap to keep cost bounded.
--
-- == Task lifecycle
--
-- 'runAgent' takes a 'TaskRegistry'.  Each 'AgentTurn' brackets a
-- register/unregister around the loop, so @!ps@ sees the running
-- dispatch and @!kill@ can cancel it via 'TaskCancelled' (which the
-- bracket cleans up before propagating).  The same task's inbox is
-- what @!btw@ pushes into.
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
    runAgent,
    agentTurn,
    defaultLimits,
  )
where

import Control.Concurrent (myThreadId, throwTo)
import Control.Exception (bracket)
import Data.Aeson (Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Log
import Max.Effects.LLM (ChatMessage (..), ChatResponse (..), LLM, ToolCall (..), chat)
import Max.Effects.Tools (Tool, Tools, invokeTool, listToolSpecs, runTools)
import Max.Tasks (TaskCancelled (..), TaskHandle (..), TaskRegistry, drainBtwInbox, registerTask, unregisterTask)
import OneBot.Types (GroupId, MessageId, UserId)

-- | Per-dispatch context the agent loop hands to its tool factory.
-- Tools like @say@ need the triggering message coordinates to thread
-- their reply correctly; ambient tools that only care about the group
-- can just project 'dcGroupId'.  'dcSelfId' is the bot's own QQ id —
-- needed when persisting outbound messages so we can attribute them
-- to the bot.
data DispatchContext = DispatchContext
  { dcGroupId :: !GroupId,
    dcMessageId :: !MessageId,
    dcUserId :: !UserId,
    dcSelfId :: !UserId
  }
  deriving stock (Show)

-- | Caps on a single agent invocation.  Per-tool and per-call HTTP
-- timeouts are configured at the 'LLM' layer; these are loop-level.
data AgentLimits = AgentLimits
  { -- | Maximum number of LLM round-trips per dispatch.  Counts each
    -- 'chat' call, whether it returned content or tool calls.
    maxTurns :: !Int
  }
  deriving stock (Show)

-- | Sane starting point: 40 turns covers a few rounds of tool use,
-- a couple of @say@ status updates, and a final summary.
defaultLimits :: AgentLimits
defaultLimits = AgentLimits {maxTurns = 40}

-- | What one agent run produced.
data AgentResult = AgentResult
  { -- | Final assistant text to show the user.  Always populated, even
    -- on abort (with a fallback explaining what went wrong).
    reply :: !Text,
    -- | Every message added to the conversation during this run —
    -- @!btw@ injections, assistant tool-call rounds, tool results,
    -- final assistant text.  Does NOT include the initial messages
    -- the caller passed in.
    appended :: ![ChatMessage],
    turnsUsed :: !Int,
    -- | 'Just' iff the loop ended for a reason other than the model
    -- producing a content response (e.g. hit 'maxTurns', LLM error).
    aborted :: !(Maybe Text)
  }
  deriving stock (Show)

--------------------------------------------------------------------------------
-- Effect.

data Agent :: Effect where
  -- | Run a full agent loop for the given dispatch.  Returns when the
  -- model emits a content response, hits 'maxTurns', or the LLM errors.
  AgentTurn :: DispatchContext -> Text -> Maybe Bool -> [ChatMessage] -> Agent m AgentResult

type instance DispatchOf Agent = Dynamic

-- | Install the agent loop on top of a stack that already has 'LLM'
-- (and 'Log', 'IOE').  The interpreter, on each 'AgentTurn':
--
--   * Registers a task in the 'TaskRegistry' (and unregisters via
--     'bracket' on exit, including 'TaskCancelled' from @!kill@).
--   * Spins up a 'Tools' scope built from the per-group factory.
--   * Drives the loop, draining the task's inbox between turns.
runAgent ::
  forall es a.
  (LLM :> es, Log :> es, IOE :> es) =>
  AgentLimits ->
  (DispatchContext -> [Tool es]) ->
  TaskRegistry ->
  Eff (Agent : es) a ->
  Eff es a
runAgent lims toolFactory taskReg = interpret $ \_ -> \case
  AgentTurn dc profile thinking msgs ->
    withRunInIO $ \run -> do
      selfTid <- myThreadId
      let cancel = throwTo selfTid TaskCancelled
      bracket
        (registerTask taskReg dc.dcGroupId "llm" cancel)
        (unregisterTask taskReg)
        ( \handle ->
            run (runTools (toolFactory dc) (loop handle profile thinking msgs))
        )
  where
    loop ::
      TaskHandle ->
      Text ->
      Maybe Bool ->
      [ChatMessage] ->
      Eff (Tools : es) AgentResult
    loop h profile thinking = go h 0 [] profile thinking

    go ::
      TaskHandle ->
      Int ->
      [ChatMessage] ->
      Text ->
      Maybe Bool ->
      [ChatMessage] ->
      Eff (Tools : es) AgentResult
    go h n appended profile thinking msgs = do
      -- Drain any !btw notes that arrived since the previous turn.
      notes <- liftIO (drainBtwInbox h)
      let (msgs', appended') = case notes of
            [] -> (msgs, appended)
            xs ->
              let btw = MsgUser ("[侧记]: " <> T.intercalate " | " xs)
               in (msgs <> [btw], appended <> [btw])
      if n >= lims.maxTurns
        then
          pure
            AgentResult
              { reply =
                  "(达到最大轮次 "
                    <> T.pack (show lims.maxTurns)
                    <> "，没收敛到最终回答)",
                appended = appended',
                turnsUsed = n,
                aborted = Just "max-turns"
              }
        else do
          specs <- listToolSpecs
          eres <- chat profile thinking msgs' specs
          case eres of
            Left err ->
              pure
                AgentResult
                  { reply = "(LLM 调用失败: " <> err <> ")",
                    appended = appended',
                    turnsUsed = n + 1,
                    aborted = Just err
                  }
            Right (ContentResp text) -> do
              let asst = MsgAssistant text
              pure
                AgentResult
                  { reply = text,
                    appended = appended' <> [asst],
                    turnsUsed = n + 1,
                    aborted = Nothing
                  }
            Right (ToolCallsResp reasoning tcs) -> do
              logInfo "agent: tool calls" $
                object
                  [ "turn" .= n,
                    "count" .= length tcs,
                    "names" .= map (.callName) tcs,
                    "has_reasoning" .= case reasoning of Just _ -> True; Nothing -> False
                  ]
              -- Carry reasoning_content into the assistant message so
              -- it round-trips back to the API on the next request —
              -- DeepSeek returns 400 otherwise.
              let asst = MsgAssistantToolCalls reasoning tcs
              toolMsgs <- traverse executeOne tcs
              let appended'' = appended' <> [asst] <> toolMsgs
              go h (n + 1) appended'' profile thinking (msgs' <> [asst] <> toolMsgs)

    executeOne :: ToolCall -> Eff (Tools : es) ChatMessage
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
          pure $ MsgTool tc.callId full
        Left err -> do
          logAttention "agent: tool failed" $
            object ["id" .= tc.callId, "name" .= tc.callName, "error" .= err]
          pure $ MsgTool tc.callId ("error: " <> err)

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

agentTurn :: Agent :> es => DispatchContext -> Text -> Maybe Bool -> [ChatMessage] -> Eff es AgentResult
agentTurn dc profile thinking msgs = send (AgentTurn dc profile thinking msgs)
