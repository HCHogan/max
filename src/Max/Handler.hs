module Max.Handler
  ( handleEvents,
  )
where

import Control.Concurrent.STM (TQueue, atomically, readTQueue)
import Control.Exception (SomeException, try)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Text qualified as T
import Log
import Max.DB.Message (insertGroupMessage)
import Max.Deps (AppDeps (..))
import Max.Forward (enqueueForwards)
import Max.Images (enqueueImages)
import OneBot.Action (Action (SendGroupMsg))
import OneBot.Event (Event (..), GroupMessage (..))
import OneBot.Segment (Segment (..), mentionsUser, renderPlainText)
import OneBot.Server (Client, send)
import OneBot.Types (GroupId (..), UserId (..))

-- | MVP handler. Persists every group message, enqueues image segments for
-- async download, replies @pong@ to @\@bot ping@. DB / queue failures are
-- logged but never tear down the handler thread.
handleEvents :: AppDeps -> Client -> TQueue Event -> LogT IO ()
handleEvents deps client q = loop
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
          persist deps gm
          liftIO (enqueueImages deps.imageQ gm)
          liftIO (enqueueForwards deps.forwardQ gm)
          onGroupMessage client gm
      loop

persist :: AppDeps -> GroupMessage -> LogT IO ()
persist deps gm = do
  eres <- liftIO (try (insertGroupMessage deps.db gm))
  case eres :: Either SomeException () of
    Right () -> pure ()
    Left e ->
      logAttention "db insert failed" $
        object ["error" .= T.pack (show e)]

onGroupMessage :: Client -> GroupMessage -> LogT IO ()
onGroupMessage client gm = do
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
    eid <-
      send
        client
        ( SendGroupMsg
            gm.groupId
            [ SegAt gm.userId,
              SegText " pong"
            ]
        )
    logInfo "replied pong" $
      object ["echo" .= eid, "to" .= fromRaw, "group_id" .= gidRaw]

-- | Drop any leading @<bot> mention from a rendered plain-text body so we
-- can match the bare command word.
stripMentions :: UserId -> T.Text -> T.Text
stripMentions (UserId u) =
  T.replace ("@" <> T.pack (show u)) ""
