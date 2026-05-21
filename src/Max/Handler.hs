module Max.Handler
  ( handleEvents,
  )
where

import Control.Concurrent.STM (TQueue, atomically, readTQueue)
import Control.Monad (forever, when)
import Data.Text qualified as T
import OneBot.Action (Action (SendGroupMsg))
import OneBot.Event (Event (..), GroupMessage (..))
import OneBot.Segment (Segment (..), mentionsUser, renderPlainText)
import OneBot.Server (Client, send)
import OneBot.Types (UserId (..))

-- | MVP handler. Pulls events off the queue and reacts to group messages
-- that @ the bot with body \"ping\" — replies \"pong\" in the same group.
-- Everything else is logged for now.
handleEvents :: Client -> TQueue Event -> IO ()
handleEvents client q = forever $ do
  atomically (readTQueue q) >>= \case
    EvHeartbeat -> pure ()
    EvLifecycle sub ->
      putStrLn $ "lifecycle: " <> T.unpack sub
    EvRaw v ->
      putStrLn $ "unhandled event: " <> show v
    EvGroupMessage gm -> onGroupMessage client gm

onGroupMessage :: Client -> GroupMessage -> IO ()
onGroupMessage client gm = do
  let UserId selfRaw = gm.selfId
      UserId fromRaw = gm.userId
      body = T.strip (stripMentions gm.selfId (renderPlainText gm.message))
  putStrLn $
    "group "
      <> show gm.groupId
      <> " from "
      <> show fromRaw
      <> ": "
      <> T.unpack (renderPlainText gm.message)
  when (mentionsUser gm.selfId gm.message && body == "ping") $ do
    _ <-
      send
        client
        ( SendGroupMsg
            gm.groupId
            [ SegAt gm.userId,
              SegText " pong"
            ]
        )
    putStrLn $ "replied pong to " <> show selfRaw <> "/" <> show fromRaw

-- | Drop any leading @<bot> mention from a rendered plain-text body so we can
-- match the bare command word.
stripMentions :: UserId -> T.Text -> T.Text
stripMentions (UserId u) =
  T.replace ("@" <> T.pack (show u)) ""
