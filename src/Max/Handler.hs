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
import Max.DB.Message (insertGroupMessage)
import Max.Effects.LLM (LLM, chat)
import Max.Effects.NapCat (NapCat, sendAction)
import Max.Forward (ForwardQueue, enqueueForwards)
import Max.Images (ImageQueue, enqueueImages)
import Max.Prompt (buildContext)
import Max.Util (catchSync)
import OneBot.Action (Action (SendGroupMsg))
import OneBot.Event (Event (..), GroupMessage (..))
import OneBot.Segment (Segment (..), mentionsUser, renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

-- | Decision derived from one group message: how (if at all) should the
-- bot react. Kept as a discrete ADT so future triggers (proactive
-- speaking, keyword watching, etc.) extend cleanly.
data Trigger
  = -- | Bot was not addressed; do nothing.
    TriggerNone
  | -- | @\@bot ping@ — fast path, no LLM.
    TriggerPong
  | -- | @\@bot ...@ with any other body. Carries the user-facing body
    -- with the @bot mention already stripped.
    TriggerLLM !T.Text
  deriving stock (Show)

classify :: GroupMessage -> Trigger
classify gm
  | not (mentionsUser gm.selfId gm.message) = TriggerNone
  | otherwise =
      let body = T.strip (stripMentions gm.selfId (renderPlainText gm.message))
       in case body of
            "ping" -> TriggerPong
            "" -> TriggerNone
            _ -> TriggerLLM body

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
  T.Text -> -- bot persona for LLM system prompt
  Int -> -- history window size for LLM context
  TQueue Event ->
  ImageQueue ->
  ForwardQueue ->
  Eff es ()
handleEvents persona historyN q imgQ fwdQ = loop
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
          onGroupMessage persona historyN gm
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
  GroupMessage ->
  Eff es ()
onGroupMessage persona historyN gm = do
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
    TriggerLLM _ -> dispatchLLM persona historyN gm

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

-- | Spawn an async to: build the prompt, call the LLM, post the reply.
-- Errors inside are caught and logged; the handler thread keeps moving
-- so other events aren't blocked while the model thinks.
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
  GroupMessage ->
  Eff es ()
dispatchLLM persona historyN gm = void $ async $
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
      ctx <- buildContext persona historyN gm
      eres <- chat ctx
      case eres of
        Left err ->
          logAttention "llm response failed" $ object ["error" .= err]
        Right text -> do
          sendAction
            ( SendGroupMsg
                gm.groupId
                [ SegReply gm.messageId,
                  SegAt gm.userId,
                  SegText (" " <> T.strip text)
                ]
            )
          logInfo "llm replied" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "len" .= T.length text
              ]

stripMentions :: UserId -> T.Text -> T.Text
stripMentions (UserId u) =
  T.replace ("@" <> T.pack (show u)) ""
