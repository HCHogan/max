-- | A single scheduler consumes trigger markers and starts ordinary Jobs.
-- Startup interrupts unfinished triggers; there is no lease or replay worker.
module Max.Monitor (monitorWorker, nextCronFire, deliveryBody) where

import Control.Monad (when)
import Data.Aeson (object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone, UTCTime, diffUTCTime, getCurrentTime)
import Effectful
import Effectful.Log (Log, logAttention)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Monitor
import Max.DB.Notify (WorkChannel (MonitorWork), waitForWorkUntil)
import Max.Effects.Blob (Blob)
import Max.Effects.Outbound (Outbound, OutboundDeliveryScope (..), OutboundRequest (..), PublicationResult (..), sendRecorded)
import Max.IR (Body (..), Phase (Canonical))
import Max.MessageKind (MessageKind (KindChat))
import Max.Monitor.Schedule (nextCronFire)
import Max.Monitor.Types (MonitorFireId (..))
import Max.Platform.Store (ConversationRoster (..), RosterIdentity (..), conversationAdvertisedCaps, conversationRoster)
import Max.Platform.Types (AdvertisedCaps (..), CanonicalMessageId)
import Max.Reply (Chunk (TextChunk))
import Max.ReplySend (ReplyTarget (..), cleanModelText, freshBudget, prepareReplyChunk)
import Max.Util (catchSync)
import OneBot.Types (GroupId (..))
import System.Cron.Parser (parseCronSchedule)

-- A small floor prevents busy looping when cancellation or a budget check
-- invalidates work between the deadline query and dispatch.
delayMicrosFor :: UTCTime -> UTCTime -> Int
delayMicrosFor now deadline = max 50000 (min 3600000000 (round (diffUTCTime deadline now * 1000000)))

monitorWorker ::
  (Blob :> es, WithConnection :> es, Outbound :> es, Log :> es, IOE :> es) =>
  TimeZone -> (ElaboratedMonitorFire -> Eff es ()) -> Eff es ()
monitorWorker tz dispatchElaborated = loop
  where
    loop = do
      now <- liftIO getCurrentTime
      deadline <- nextMonitorDeadline now
      work <- waitForWorkUntil (maybe 3600000000 (delayMicrosFor now) deadline) MonitorWork readyWork
      mapM_ processWork work
      loop

    readyWork = do
      now <- liftIO getCurrentTime
      _ <- admitDueTimeMonitors now
      canned <- pendingCannedMonitorFires 50
      elaborated <- pendingElaboratedMonitorFires now 50
      pure (map Left canned <> map Right elaborated)

    processWork = \case
      Right fire ->
        dispatchElaborated fire `catchSync` \err -> do
          _ <- expireElaboratedMonitorFire fire.emfFireId (T.pack (show err))
          logAttention "monitor dispatch failed; trigger not retried" (object ["fire_id" .= fire.emfFireId.unMonitorFireId, "error" .= show err])
      Left fire -> do
        now <- liftIO getCurrentTime
        let next = fire.cmfCron >>= either (const Nothing) (\schedule -> nextCronFire tz schedule now) . parseCronSchedule
        started <- beginCannedMonitorFire fire.cmfFireId next
        when started $ do
          outcome <- deliver fire `catchSync` (pure . PublicationFailed . T.pack . show)
          result <- case outcome of
            Published canonical -> pure (Right canonical)
            PublicationFailed err -> do
              -- A canonical commit can succeed before its caller sees an error.
              -- Record that fact without repeating the external send.
              committed <- lookupMonitorFireOutput fire.cmfFireId
              pure (maybe (Left err) Right committed)
          finishCannedMonitorFire fire.cmfFireId result
          case result of
            Left err -> logAttention "reminder publication failed; not retried" (object ["fire_id" .= fire.cmfFireId.unMonitorFireId, "error" .= err])
            Right _ -> pure ()

    deliver fire = do
      let group = GroupId fire.cmfGroupId
      (body, replyTo) <- deliveryBody group fire.cmfText
      sendRecorded
        OutboundRequest
          { orKind = KindChat,
            orGroupId = group,
            orBody = body,
            orReplyTo = replyTo,
            orDeliveryScope = DeliverConversation,
            orTurnOutput = Nothing,
            orMonitorFireId = Just fire.cmfFireId
          }

-- | A reminder's body owns its mentions. Never add an extra mention of the
-- initiator; resolve the stored placeholders exactly as ordinary model text.
deliveryBody ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  GroupId -> Text -> Eff es (Body 'Canonical, Maybe CanonicalMessageId)
deliveryBody groupId@(GroupId group) body = do
  roster <- conversationRoster group
  caps <- conversationAdvertisedCaps group Nothing
  let target =
        ReplyTarget
          { rtGroupId = groupId,
            rtRosterNames = [(name, identity.riPrincipalId) | identity <- roster.crIdentities, Just name <- [identity.riDisplayName]],
            rtSelfPrincipal = Nothing,
            rtStickers = caps.canMedia,
            rtCanReply = caps.canReply,
            rtCanMention = caps.canMention,
            rtCanFace = caps.canFace,
            rtCanImage = caps.canMedia,
            rtTurnOutputContext = Nothing
          }
  (_, prepared) <- prepareReplyChunk target freshBudget (TextChunk ("⏰ 提醒：" <> cleanModelText body))
  pure $ case prepared of
    Just (resolved, replyTo, _) -> (resolved, replyTo)
    Nothing -> (Body [], Nothing)
