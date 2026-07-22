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
--      append a synthetic @MsgUser "[btw]: …"@ before the next chat
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
    ToolImage (..),
    queueToolImage,
    runAgent,
    agentTurn,
    defaultLimits,
  )
where

import Control.Concurrent (myThreadId, throwTo)
import Control.Concurrent.STM (TVar, atomically, readTVar, writeTVar)
import Control.Monad (unless)
import Data.Aeson (Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Exception (bracket)
import Effectful.Log
import Max.Effects.LLM (ChatMessage (..), ChatResponse (..), ContentBlock (..), LLM, ToolCall (..), chat)
import Max.Effects.NapCat (NapCat, sendAction)
import Max.Effects.Tools (Tool, Tools, invokeTool, listToolSpecs, runTools)
import Max.Tasks (TaskCancelled (..), TaskHandle (..), TaskRegistry, drainBtwInbox, registerTask, unregisterTask)
import OneBot.Action (sendChatMsg)
import OneBot.Segment (Segment (SegText))
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
    dcSelfId :: !UserId,
    -- | Effective debug mode for this dispatch (config default,
    -- possibly overridden per session via !debug).  When on, each
    -- tool-call round is announced in the group.
    dcDebug :: !Bool,
    -- | Whether the active profile is multimodal.  The tool factory
    -- gates capability-heavy tools (e.g. the browser toolset) on this.
    dcMultimodal :: !Bool,
    -- | Effective sticker toggle for this dispatch (config default,
    -- possibly overridden per session via !sticker on/off).  The tool
    -- factory gates the send_sticker tool on this.
    dcStickers :: !Bool,
    -- | The group's member ids, fetched from NapCat once per dispatch.
    -- Whitelist for converting raw @\@\<qq\>@ spans in LLM-authored
    -- outbound text into real at-segments
    -- ('OneBot.Segment.segmentMentions').  'Nothing' when unavailable
    -- (private chat, fetch failure) — conversion then checks syntax
    -- only.
    dcMentionable :: !(Maybe (Set UserId)),
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
queueToolImage :: IOE :> es => DispatchContext -> ToolImage -> Eff es Bool
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
  AgentTurn :: DispatchContext -> Text -> [ChatMessage] -> Agent m AgentResult

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
  (LLM :> es, NapCat :> es, Log :> es, IOE :> es) =>
  AgentLimits ->
  (DispatchContext -> [Tool es]) ->
  TaskRegistry ->
  Eff (Agent : es) a ->
  Eff es a
runAgent lims toolFactory taskReg = interpret $ \_ -> \case
  AgentTurn dc profile msgs -> do
    selfTid <- liftIO myThreadId
    let cancel = throwTo selfTid TaskCancelled
    bracket
      (liftIO (registerTask taskReg dc.dcGroupId "llm" cancel))
      (liftIO . unregisterTask taskReg)
      ( \handle ->
          runTools (toolFactory dc) (loop dc handle profile msgs)
      )
  where
    loop ::
      DispatchContext ->
      TaskHandle ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : es) AgentResult
    loop dc h profile = go dc h 0 [] profile

    go ::
      DispatchContext ->
      TaskHandle ->
      Int ->
      [ChatMessage] ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : es) AgentResult
    go dc h n appended profile msgs = do
      -- Drain any !btw notes that arrived since the previous turn.
      notes <- liftIO (drainBtwInbox h)
      let (msgs', appended') = case notes of
            [] -> (msgs, appended)
            xs -> (msgs <> [btwMsg xs], appended <> [btwMsg xs])
      if n >= lims.maxTurns
        then finalAnswer n appended' profile msgs'
        else do
          specs <- listToolSpecs
          eres <- chat profile (capToolResults toolResultBudget msgs') specs
          case eres of
            Left err ->
              pure
                AgentResult
                  { reply = Nothing,
                    appended = appended',
                    turnsUsed = n + 1,
                    aborted = Just err
                  }
            Right (ContentResp text) -> do
              -- A !btw note that raced in during this final call would
              -- be lost — the task unregisters right after we return,
              -- and the reply it was meant to steer is already written.
              -- If any arrived, loop instead: the unsent draft stays in
              -- the conversation and the model re-answers with the
              -- note in view.
              lateNotes <- liftIO (drainBtwInbox h)
              case lateNotes of
                [] ->
                  pure
                    AgentResult
                      { reply = Just text,
                        appended = appended' <> [MsgAssistant text],
                        turnsUsed = n + 1,
                        aborted = Nothing
                      }
                xs -> do
                  logInfo "agent: btw notes raced final answer, continuing" $
                    object ["count" .= length xs]
                  let newMsgs = [MsgAssistant text, btwMsg xs]
                  go dc h (n + 1) (appended' <> newMsgs) profile (msgs' <> newMsgs)
            Right (ToolCallsResp raw tcs) -> do
              logInfo "agent: tool calls" $
                object
                  [ "turn" .= n,
                    "count" .= length tcs,
                    "names" .= map (.callName) tcs
                  ]
              announceToolCalls dc tcs
              -- Carry the provider's message verbatim so its thinking
              -- output round-trips back to the API on the next
              -- request — DeepSeek returns 400 otherwise.
              let asst = MsgAssistantToolCalls raw tcs
              toolMsgs <- traverse executeOne tcs
              imgMsgs <- drainToolImages dc
              let newMsgs = [asst] <> toolMsgs <> imgMsgs
              go dc h (n + 1) (appended' <> newMsgs) profile (msgs' <> newMsgs)

    -- Hit the turn cap: make one final tool-free chat call so the user
    -- gets a real answer built from whatever the loop already gathered,
    -- rather than a bare "max turns" error.  Empty tool specs force a
    -- content response; a synthetic note tells the model to wrap up.
    finalAnswer ::
      Int ->
      [ChatMessage] ->
      Text ->
      [ChatMessage] ->
      Eff (Tools : es) AgentResult
    finalAnswer n appended profile msgs = do
      logInfo "agent: max turns reached, forcing final answer" $
        object ["turns" .= n]
      let capNote =
            MsgUser
              "[system] 工具调用轮次已用满，别再调用任何工具了。\
              \直接根据目前已经掌握的信息，给用户一个最终回复。"
      eres <-
        chat profile (capToolResults toolResultBudget (msgs <> [capNote])) []
      let (mText, ab) = case eres of
            Right (ContentResp t) | not (T.null (T.strip t)) -> (Just t, Just "max-turns")
            Right _ -> (Nothing, Just "max-turns")
            Left err -> (Nothing, Just err)
      pure
        AgentResult
          { reply = mText,
            appended = appended <> [capNote] <> [MsgAssistant t | Just t <- [mText]],
            turnsUsed = n + 1,
            aborted = ab
          }

    -- Post one compact status line per tool call to the group so
    -- members can see what the bot is doing mid-task.  Only when the
    -- dispatch runs with debug on (config default / !debug).
    -- Fire-and-forget: a lost status line must never fail the
    -- dispatch.  Tools whose whole point is visible group output are
    -- skipped — announcing them would just double the noise.
    announceToolCalls :: DispatchContext -> [ToolCall] -> Eff (Tools : es) ()
    announceToolCalls dc tcs = do
      let visible = [tc | tc <- tcs, tc.callName `notElem` silentTools]
          line tc = "⚙ " <> tc.callName <> " " <> previewJson 1000 tc.callArguments
      unless (not dc.dcDebug || null visible) $
        sendAction $
          sendChatMsg dc.dcGroupId [SegText (T.intercalate "\n" (map line visible))]

    btwMsg :: [Text] -> ChatMessage
    btwMsg xs = MsgUser ("[btw]: " <> T.intercalate " | " xs)

    silentTools :: [Text]
    silentTools = ["say", "send_image_from_sandbox", "send_file_from_sandbox"]

    -- Images tools queued this round, packaged as one user message of
    -- alternating label/image blocks (leading text block, never two
    -- adjacent text blocks — the shape strict providers accept).
    -- Injected AFTER all tool-result messages so every tool_call id is
    -- answered first, as the OpenAI wire requires.
    drainToolImages :: DispatchContext -> Eff (Tools : es) [ChatMessage]
    drainToolImages dc = do
      imgs <- liftIO . atomically $ do
        (n, is) <- readTVar dc.dcToolImages
        writeTVar dc.dcToolImages (n, [])
        pure is
      pure
        [ MsgUserBlocks (concat [[TextBlock i.tiLabel, mediaBlock i.tiDataUrl] | i <- imgs])
        | not (null imgs)
        ]
      where
        -- Videos ride the same queue (and budget); the data URL's
        -- mime prefix decides the wire block type.
        mediaBlock u
          | "data:video/" `T.isPrefixOf` u = VideoDataUrl u
          | otherwise = ImageDataUrl u

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

-- | Total tool-result content, in characters, kept at full size before
-- older results start getting trimmed.  Individual tools already cap
-- their own output (~16 KiB), but a long multi-round sandbox loop can
-- still stack dozens of those; this bounds the whole conversation.
toolResultBudget :: Int
toolResultBudget = 60000

-- | Cap the combined size of tool-result content sent to the model.
-- Walks newest-first: recent 'MsgTool' results stay full until the
-- running total passes @budget@, then older ones are shrunk to a short
-- stub.  Every 'MsgTool' is preserved (so it still pairs with its
-- assistant @tool_call@ — dropping one would make the request invalid);
-- only the text content of the oldest results is trimmed.
capToolResults :: Int -> [ChatMessage] -> [ChatMessage]
capToolResults budget = reverse . go budget . reverse
  where
    go _ [] = []
    go rem_ (m : rest) = case m of
      MsgTool cid content
        | rem_ <= 0 -> MsgTool cid (stub content) : go 0 rest
        | otherwise ->
            let len = T.length content
             in if len <= rem_
                  then m : go (rem_ - len) rest
                  else MsgTool cid (T.take rem_ content <> elision) : go 0 rest
      _ -> m : go rem_ rest
    stub content = T.take 300 content <> elision
    elision = "\n…[older tool results truncated]"

agentTurn :: Agent :> es => DispatchContext -> Text -> [ChatMessage] -> Eff es AgentResult
agentTurn dc profile msgs = send (AgentTurn dc profile msgs)
