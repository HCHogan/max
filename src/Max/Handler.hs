module Max.Handler
  ( handleEvents,
  )
where

import Control.Concurrent.STM (TQueue, atomically, readTQueue)
import Control.Monad (unless, void)
import Data.Aeson (Value, withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent.Async (Concurrent, async)
import Effectful.Exception (SomeException, fromException, try)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Command.Dispatcher qualified as CmdDispatch
import Max.Command.Dispatcher (DispatchResult (..))
import Max.Command.Parser (parseCommand)
import Max.DB.History (HistoryItem (..), fetchMessage)
import Max.DB.Message (insertGroupMessage, insertOutbound)
import Max.Effects.Agent (Agent, AgentResult (..), DispatchContext (..), agentTurn)
import Max.Effects.LLM (LLM, isProfileMultimodal)
import Max.Effects.NapCat (NapCat, callAction, sendAction)
import Max.Env (BotEnv (..))
import Max.Files (FileQueue, enqueueFiles)
import Max.Forward (ForwardQueue, enqueueForwards)
import Max.Images (ImageQueue, enqueueImages)
import Max.Persistence (PersistMode, isEphemeral, withEphemeral)
import Max.Prompt (buildContext)
import Max.Session (Session (..), loadSession, readSession, updateSession)
import Max.Tasks (TaskCancelled)
import Max.Util (catchSync)
import OneBot.Action (Action (SendGroupMsg), Response (..))
import OneBot.Event (Event (..), GroupMessage (..))
import OneBot.Segment (Segment (..), mentionsUser, renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

-- | Decision derived from one group message.
data Trigger
  = -- | Bot was not addressed and message is not a command; do nothing.
    TriggerNone
  | -- | @\@bot ping@ — fast path, no LLM.
    TriggerPong
  | -- | @\@bot ...@ with any other body. Carries the user-facing body
    -- with the @bot mention already stripped.
    TriggerLLM !T.Text
  | -- | Message is a @!@-command (with or without @-mention).  Dispatch
    -- through 'Max.Command.Dispatcher'; no LLM.
    TriggerCommand !T.Text
  | -- | Malformed command (starts with @!ident@ but parser failed).
    -- Surface the error back to the user.
    TriggerCommandError !T.Text
  deriving stock (Show)

-- | @repliesToBot@ = the message quotes (replies to) one of the
-- bot's own messages; the caller resolves that via DB lookup.  A
-- reply to the bot counts as addressing it, same as an @-mention.
classify :: Bool -> GroupMessage -> Trigger
classify repliesToBot gm =
  let raw = T.strip (renderPlainText gm.message)
      stripped = T.strip (stripMentions gm.selfId raw)
   in case parseCommand stripped of
        Right (Just _) -> TriggerCommand stripped
        Left err -> TriggerCommandError err
        Right Nothing
          | not (mentionsUser gm.selfId gm.message) && not repliesToBot -> TriggerNone
          | otherwise -> case stripped of
              "ping" -> TriggerPong
              -- A bare @bot (or bare reply) still triggers — the
              -- model sees the ambient/reply context and reacts.
              _ -> TriggerLLM stripped

-- | App-lived event loop. Persists every group message, enqueues image
-- and forward jobs, dispatches @\@bot@ traffic. DB and dispatch failures
-- are logged but never tear down the loop.
handleEvents ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  TQueue Event ->
  ImageQueue ->
  ForwardQueue ->
  FileQueue ->
  Eff es ()
handleEvents q imgQ fwdQ fileQ = loop
  where
    loop = do
      ev <- liftIO (atomically (readTQueue q))
      case ev of
        EvHeartbeat -> pure ()
        EvLifecycle sub ->
          logInfo "lifecycle" $ object ["sub_type" .= sub]
        EvRaw v ->
          logTrace "unhandled event" v
        EvGroupMessage gm -> do
          persist gm
          liftIO (enqueueImages imgQ gm)
          liftIO (enqueueForwards fwdQ gm)
          enqueueFiles fileQ gm
          onGroupMessage gm
      loop

persist :: (Log :> es, WithConnection :> es, IOE :> es) => GroupMessage -> Eff es ()
persist gm = do
  eres <- try (insertGroupMessage gm)
  case eres :: Either SomeException () of
    Right () -> pure ()
    Left e ->
      logAttention "db insert failed" $
        object ["error" .= T.pack (show e)]

onGroupMessage ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  GroupMessage ->
  Eff es ()
onGroupMessage gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
  logInfo "group message" $
    object
      [ "group_id" .= gidRaw,
        "user_id" .= fromRaw,
        "text" .= renderPlainText gm.message
      ]
  -- Cheap pure pass first; only when it says "not addressed" AND the
  -- message quotes something do we pay a PK lookup to see whether
  -- the quoted message was ours (reply-to-bot counts as addressing).
  trig <- case classify False gm of
    TriggerNone
      | Just rid <- listToMaybe [m | SegReply (MessageId m) <- gm.message] -> do
          mQuoted <- fetchMessage rid
          let UserId selfRaw = gm.selfId
          pure $ case mQuoted of
            Just quoted | quoted.userId == selfRaw -> classify True gm
            _ -> TriggerNone
    t -> pure t
  case trig of
    TriggerNone -> pure ()
    TriggerPong -> sendPong gm
    TriggerCommand body -> dispatchCommand gm body
    TriggerCommandError err -> replyText gm ("命令解析失败:\n" <> err)
    TriggerLLM _ -> dispatchLLM gm

--------------------------------------------------------------------------------
-- Commands.

dispatchCommand ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  GroupMessage ->
  T.Text ->
  Eff es ()
dispatchCommand gm body = localDomain "cmd" $ do
  case parseCommand body of
    Left err -> replyText gm ("命令解析失败:\n" <> err)
    Right Nothing -> pure () -- shouldn't reach here; classify already filtered
    Right (Just cmd) -> do
      env :: BotEnv <- ask
      t <- loadSession env.beSessions env.beDefaultModel gm.groupId
      logInfo "command" $ object ["cmd" .= T.pack (show cmd)]
      let replyTarget = listToMaybe [m | SegReply (MessageId m) <- gm.message]
      result <- CmdDispatch.execute t gm.groupId replyTarget cmd
      case result of
        ReplyText reply -> replyText gm reply
        EphemeralAsk askBody -> do
          logInfo "btw: ephemeral dispatch" $
            object ["len" .= T.length askBody]
          -- Rebuild the trigger with the !btw body as the user
          -- message; preserve everything else (reply target, sender,
          -- self id) so buildContext sees a normal @-mention.
          let virtualGm =
                gm
                  { message =
                      [ SegAt gm.selfId,
                        SegText (" " <> askBody)
                      ]
                  }
          withEphemeral $ dispatchLLM virtualGm

--------------------------------------------------------------------------------
-- LLM dispatch.

sendPong :: (NapCat :> es, Log :> es) => GroupMessage -> Eff es ()
sendPong gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
  sendAction
    ( SendGroupMsg
        gm.groupId
        [ SegReply gm.messageId,
          SegAt gm.userId,
          SegText " pong"
        ]
    )
  logInfo "replied pong" $ object ["to" .= fromRaw, "group_id" .= gidRaw]

-- | Spawn an async to build the prompt, call the LLM, post the reply,
-- and append the (user, assistant) turn to the session history.
dispatchLLM ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  GroupMessage ->
  Eff es ()
dispatchLLM gm = void $ async $
  localDomain "llm" $ do
    let UserId fromRaw = gm.userId
        GroupId gidRaw = gm.groupId
        MessageId midRaw = gm.messageId
    logInfo "llm dispatch" $
      object
        [ "group_id" .= gidRaw,
          "user_id" .= fromRaw,
          "message_id" .= midRaw
        ]
    work `catchSync` \e ->
      case fromException e :: Maybe TaskCancelled of
        Just _ ->
          -- User-initiated !kill — quieter log, not an error.
          logInfo "llm dispatch cancelled" $
            object ["group_id" .= gidRaw]
        Nothing ->
          logAttention "llm dispatch crashed" $
            object ["error" .= T.pack (show (e :: SomeException))]
  where
    work = do
      env :: BotEnv <- ask
      t <- loadSession env.beSessions env.beDefaultModel gm.groupId
      s <- liftIO (readSession t)
      multimodal <- isProfileMultimodal s.model
      (ctx, drained) <- buildContext env.bePersona env.beHistoryWindow multimodal env.beBlobRoot s gm
      let debugEff = maybe env.beDebugDefault id s.debugOverride
          dc = DispatchContext gm.groupId gm.messageId gm.userId gm.selfId debugEff multimodal
      result <- agentTurn dc s.model s.thinkingOverride ctx
      -- The outbound message already @-mentions the sender via 'SegAt'
      -- (rendered as their nickname).  The model, having seen prior
      -- turns where mentions render as raw "@<qq>", tends to also write
      -- "@<sender-qq>" into its reply text — producing a double @.
      -- Strip the sender's raw @-mention from the model text so only the
      -- structured SegAt remains.
      let stripped = T.strip (stripMentions gm.userId result.reply)
      -- callAction so we get the message_id back, then persist this
      -- outbound message into the messages table.  That's where
      -- subsequent dispatches will read this turn's assistant reply
      -- back from when reconstructing mention history.
      sendAndPersistReply gm stripped
      -- Drain consumed btw notes — but only when persisting; an
      -- ephemeral dispatch (e.g. !btw one-shot) must not eat the
      -- queue (the notes are still waiting for a real turn).
      ephemeral <- isEphemeral
      unless ephemeral $
        updateSession t $ \sess ->
          let sess' =
                sess
                  { btwNotes =
                      if null drained
                        then sess.btwNotes
                        else drop (length drained) sess.btwNotes
                  }
           in (sess', ())
      logInfo "llm replied" $
        object
          [ "to" .= (let UserId u = gm.userId in u),
            "len" .= T.length stripped,
            "turns" .= result.turnsUsed,
            "appended" .= length result.appended,
            "btw_drained" .= length drained,
            "aborted" .= result.aborted
          ]

--------------------------------------------------------------------------------
-- Reply helper.

-- | Fire-and-forget reply (no persist).  Used for pong, command
-- responses, parse errors — chitchat we don't want polluting the
-- LLM mention history.
replyText :: NapCat :> es => GroupMessage -> T.Text -> Eff es ()
replyText gm body =
  sendAction
    ( SendGroupMsg
        gm.groupId
        [ SegReply gm.messageId,
          SegAt gm.userId,
          SegText (" " <> body)
        ]
    )

-- | Send the LLM's final reply and persist it into the messages
-- table (so future dispatches can read this back as part of the
-- mention history).  Uses 'callAction' instead of 'sendAction' to
-- get NapCat's assigned @message_id@ from the response.  If the
-- send or message_id extraction fails, logs and gives up
-- persistence — the user still gets the reply (NapCat printed it),
-- only the bot's memory loses this turn.
sendAndPersistReply ::
  ( NapCat :> es,
    WithConnection :> es,
    Reader PersistMode :> es,
    Log :> es,
    IOE :> es
  ) =>
  GroupMessage ->
  T.Text ->
  Eff es ()
sendAndPersistReply gm body = do
  let segs =
        [ SegReply gm.messageId,
          SegAt gm.userId,
          SegText (" " <> body)
        ]
  eres <- callAction (SendGroupMsg gm.groupId segs) 30000
  case eres of
    Left err ->
      logAttention "llm reply send failed" $ object ["error" .= err]
    Right (Response _ rc payload _)
      | rc /= 0 ->
          logAttention "llm reply retcode bad" $ object ["retcode" .= rc]
      | otherwise -> case extractOutMid payload of
          Nothing ->
            logAttention "no message_id in send_group_msg response" $
              object ["payload" .= payload]
          Just outMid -> do
            -- The reply already went out over NapCat — that's a real
            -- side effect we can't undo.  Only the messages-table
            -- write is gated, so an ephemeral turn doesn't show up
            -- in next dispatch's mention history.
            ephemeral <- isEphemeral
            unless ephemeral $
              insertOutbound gm.groupId gm.selfId "max" (MessageId outMid) segs

extractOutMid :: Value -> Maybe Int64
extractOutMid v = case parseEither (withObject "send_resp" (\o -> o .: "message_id")) v of
  Right (mid :: Int64) -> Just mid
  Left _ -> Nothing

stripMentions :: UserId -> T.Text -> T.Text
stripMentions (UserId u) =
  T.replace ("@" <> T.pack (show u)) ""
