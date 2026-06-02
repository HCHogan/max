module Max.Handler
  ( handleEvents,
  )
where

import Control.Concurrent.STM (TQueue, atomically, readTQueue)
import Control.Exception (SomeException, try)
import Control.Monad (void)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent.Async (Concurrent, async)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.Command.Dispatcher qualified as CmdDispatch
import Max.Command.Parser (parseCommand)
import Max.DB.Message (insertGroupMessage)
import Max.Effects.LLM (ChatMessage (..), LLM, chat)
import Max.Effects.NapCat (NapCat, sendAction)
import Max.Forward (ForwardQueue, enqueueForwards)
import Max.Images (ImageQueue, enqueueImages)
import Max.Prompt (buildContext)
import Max.Session (Session (..), SessionRegistry, loadSession, readSession, updateSession)
import Max.Session qualified as Session
import Max.Util (catchSync)
import OneBot.Action (Action (SendGroupMsg))
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

classify :: GroupMessage -> Trigger
classify gm =
  let raw = T.strip (renderPlainText gm.message)
      stripped = T.strip (stripMentions gm.selfId raw)
   in case parseCommand stripped of
        Right (Just _) -> TriggerCommand stripped
        Left err -> TriggerCommandError err
        Right Nothing
          | not (mentionsUser gm.selfId gm.message) -> TriggerNone
          | otherwise -> case stripped of
              "ping" -> TriggerPong
              "" -> TriggerNone
              _ -> TriggerLLM stripped

-- | App-lived event loop. Persists every group message, enqueues image
-- and forward jobs, dispatches @\@bot@ traffic. DB and dispatch failures
-- are logged but never tear down the loop.
handleEvents ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Concurrent :> es,
    IOE :> es
  ) =>
  T.Text -> -- default bot persona
  Int -> -- history window size for ambient context
  SessionRegistry ->
  T.Text -> -- default LLM profile name (for new sessions)
  TQueue Event ->
  ImageQueue ->
  ForwardQueue ->
  Eff es ()
handleEvents persona historyN reg defaultModel q imgQ fwdQ = loop
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
          onGroupMessage persona historyN reg defaultModel gm
      loop

persist :: (Log :> es, WithConnection :> es, IOE :> es) => GroupMessage -> Eff es ()
persist gm = do
  eres <- withRunInIO $ \run -> try (run (insertGroupMessage gm))
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
    Concurrent :> es,
    IOE :> es
  ) =>
  T.Text ->
  Int ->
  SessionRegistry ->
  T.Text ->
  GroupMessage ->
  Eff es ()
onGroupMessage persona historyN reg defaultModel gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
  logInfo "group message" $
    object
      [ "group_id" .= gidRaw,
        "user_id" .= fromRaw,
        "text" .= renderPlainText gm.message
      ]
  case classify gm of
    TriggerNone -> pure ()
    TriggerPong -> sendPong gm
    TriggerCommand body -> dispatchCommand reg defaultModel gm body
    TriggerCommandError err -> replyText gm ("命令解析失败:\n" <> err)
    TriggerLLM _ -> dispatchLLM persona historyN reg defaultModel gm

--------------------------------------------------------------------------------
-- Commands.

dispatchCommand ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    IOE :> es
  ) =>
  SessionRegistry ->
  T.Text ->
  GroupMessage ->
  T.Text ->
  Eff es ()
dispatchCommand reg defaultModel gm body = localDomain "cmd" $ do
  case parseCommand body of
    Left err -> replyText gm ("命令解析失败:\n" <> err)
    Right Nothing -> pure () -- shouldn't reach here; classify already filtered
    Right (Just cmd) -> do
      t <- loadSession reg defaultModel gm.groupId
      logInfo "command" $ object ["cmd" .= T.pack (show cmd)]
      reply <- CmdDispatch.execute t cmd
      replyText gm reply

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
    Concurrent :> es,
    IOE :> es
  ) =>
  T.Text ->
  Int ->
  SessionRegistry ->
  T.Text ->
  GroupMessage ->
  Eff es ()
dispatchLLM defaultPersona historyN reg defaultModel gm = void $ async $
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
      logAttention "llm dispatch crashed" $
        object ["error" .= T.pack (show (e :: SomeException))]
  where
    work = do
      t <- loadSession reg defaultModel gm.groupId
      s <- liftIO (readSession t)
      (ctx, drained) <- buildContext defaultPersona historyN s gm
      eres <- chat s.model ctx
      case eres of
        Left err ->
          logAttention "llm response failed" $ object ["error" .= err]
        Right text -> do
          let stripped = T.strip text
              -- Use the stripped user-facing body (no @bot mention) as
              -- the user turn we record in history.
              userBody =
                T.strip (stripMentions gm.selfId (renderPlainText gm.message))
              userMsg = ChatMessage "user" userBody
              asstMsg = ChatMessage "assistant" stripped
          replyText gm stripped
          -- Persist the turn + drain the btw notes that were consumed
          -- into this prompt.  One write through DB.
          updateSession t $ \sess ->
            let sess1 = Session.appendHistoryTurn userMsg asstMsg sess
                sess2 =
                  if null drained
                    then sess1
                    else sess1 {btwNotes = drop (length drained) sess1.btwNotes}
             in (sess2, ())
          logInfo "llm replied" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "len" .= T.length text,
                "btw_drained" .= length drained
              ]

--------------------------------------------------------------------------------
-- Reply helper.

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

stripMentions :: UserId -> T.Text -> T.Text
stripMentions (UserId u) =
  T.replace ("@" <> T.pack (show u)) ""
