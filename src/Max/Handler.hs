module Max.Handler
  ( handleEvents,
  )
where

import Control.Concurrent.STM (TQueue, atomically, readTQueue)
import Control.Exception (SomeException, try)
import Control.Monad (when)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Max.DB.Message (insertGroupMessage)
import Max.Effects.Db (Db)
import Max.Effects.NapCat (NapCat, sendAction)
import Max.Forward (ForwardQueue, enqueueForwards)
import Max.Images (ImageQueue, enqueueImages)
import OneBot.Action (Action (SendGroupMsg))
import OneBot.Event (Event (..), GroupMessage (..))
import OneBot.Segment (Segment (..), mentionsUser, renderPlainText)
import OneBot.Types (GroupId (..), UserId (..))

-- | App-lived event loop. Persists every group message, enqueues image
-- and forward jobs, replies @pong@ to @\@bot ping@. DB failures are
-- logged but never tear down the loop.
handleEvents ::
  (Log :> es, Db :> es, NapCat :> es, IOE :> es) =>
  TQueue Event ->
  ImageQueue ->
  ForwardQueue ->
  Eff es ()
handleEvents q imgQ fwdQ = loop
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
          onGroupMessage gm
      loop

persist :: (Log :> es, Db :> es, IOE :> es) => GroupMessage -> Eff es ()
persist gm = do
  eres <- withRunInIO $ \run -> try (run (insertGroupMessage gm))
  case eres :: Either SomeException () of
    Right () -> pure ()
    Left e ->
      logAttention "db insert failed" $
        object ["error" .= T.pack (show e)]

onGroupMessage ::
  (Log :> es, NapCat :> es) =>
  GroupMessage ->
  Eff es ()
onGroupMessage gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
      body = T.strip (stripMentions gm.selfId (renderPlainText gm.message))
  logInfo "group message" $
    object
      [ "group_id" .= gidRaw,
        "user_id" .= fromRaw,
        "text" .= renderPlainText gm.message
      ]
  when (mentionsUser gm.selfId gm.message && body == "ping") $ do
    sendAction
      ( SendGroupMsg
          gm.groupId
          [ SegAt gm.userId,
            SegText " pong"
          ]
      )
    logInfo "replied pong" $
      object ["to" .= fromRaw, "group_id" .= gidRaw]

stripMentions :: UserId -> T.Text -> T.Text
stripMentions (UserId u) =
  T.replace ("@" <> T.pack (show u)) ""
