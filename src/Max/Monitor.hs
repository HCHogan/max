-- | Event-driven ADR 006 monitor scheduler. Schedule and ledger observations
-- admit durable fires; leased workers either publish canned text or admit one
-- fresh ordinary elaborated turn with restart-safe provenance.
module Max.Monitor
  ( monitorWorker,
    nextCronFire,
    CannedRetry (..),
    maxCannedAttempts,
    cannedRetryDecision,
  )
where

import Control.Monad (when)
import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Ord (clamp)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
  ( TimeZone,
    UTCTime,
    addUTCTime,
    diffUTCTime,
    getCurrentTime,
    localTimeToUTC,
    utc,
    utcToLocalTime,
  )
import Effectful
import Effectful.Log (Log, logAttention, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Monitor
  ( CannedMonitorFire (..),
    ElaboratedMonitorFire (..),
    admitDueTimeMonitors,
    claimCannedMonitorFires,
    claimElaboratedMonitorFires,
    completeCannedMonitorFire,
    lookupMonitorFireOutput,
    nextMonitorDeadline,
    recordMonitorFireFailure,
  )
import Max.DB.Notify (WorkChannel (MonitorWork), claimOrWaitUntil)
import Max.Effects.Outbound
  ( Outbound,
    OutboundDeliveryScope (..),
    OutboundRequest (..),
    SendOutcome (..),
    sendRecorded,
  )
import Max.IR (Body (..), MentionTarget (..), Node (..), Phase (Canonical))
import Max.MessageKind (MessageKind (KindChat))
import Max.Monitor.Types (MonitorFireId (..), MonitorId (..), MonitorRef (..))
import Max.Platform.Store (resolveMentionIdentities)
import Max.Platform.Types (PrincipalId (..))
import Max.Util (catchSync, tshow)
import OneBot.Types (GroupId (..), isPrivateChat)
import System.Cron (CronSchedule, nextMatch)
import System.Cron.Parser (parseCronSchedule)

-- | The next UTC instant strictly after the supplied time whose wall clock in
-- the configured display timezone matches the cron schedule.
nextCronFire :: TimeZone -> CronSchedule -> UTCTime -> Maybe UTCTime
nextCronFire tz schedule after = do
  let pseudo = localTimeToUTC utc (utcToLocalTime tz after)
  pseudoNext <- nextMatch schedule pseudo
  pure (localTimeToUTC tz (utcToLocalTime utc pseudoNext))

capMicros :: Int
capMicros = 3600 * 1000000

-- | The floor is load-bearing, not politeness.  'nextMonitorDeadline' and the
-- claim queries are separate SQL: any row the first considers due and the
-- second declines to hand out would otherwise spin this loop at zero delay
-- against PostgreSQL.  Waiting only happens when nothing was claimable, so
-- the floor costs no latency on the work path.
delayMicrosFor :: UTCTime -> UTCTime -> Int
delayMicrosFor now deadline =
  let micros = realToFrac (diffUTCTime deadline now) * 1e6 :: Double
   in round (clamp (fromIntegral floorMicros, fromIntegral capMicros) micros)

floorMicros :: Int
floorMicros = 50 * 1000

maxCannedAttempts :: Int
maxCannedAttempts = 5

data CannedRetry
  = RetryCannedAt !UTCTime
  | ParkCanned
  deriving stock (Show, Eq)

cannedRetryDecision :: UTCTime -> Int -> CannedRetry
cannedRetryDecision now failedAttempt
  | failedAttempt >= maxCannedAttempts = ParkCanned
  | otherwise = RetryCannedAt (addUTCTime (fromIntegral delaySecs) now)
  where
    delaySecs :: Int
    delaySecs = case failedAttempt of
      1 -> 30
      2 -> 120
      3 -> 600
      _ -> 1800

claimLeaseSeconds :: Int
claimLeaseSeconds = 60

claimBatchSize :: Int
claimBatchSize = 50

monitorWorker ::
  (WithConnection :> es, Outbound :> es, Log :> es, IOE :> es) =>
  TimeZone ->
  Text ->
  (ElaboratedMonitorFire -> Eff es ()) ->
  Eff es ()
monitorWorker tz owner dispatchElaborated = loop
  where
    loop = do
      now <- liftIO getCurrentTime
      deadline <- nextMonitorDeadline now
      let waitMicros = maybe capMicros (delayMicrosFor now) deadline
      work <- claimOrWaitUntil waitMicros MonitorWork claimWork
      mapM_ processWork work
      loop

    claimWork = do
      observedAt <- liftIO getCurrentTime
      _ <- admitDueTimeMonitors observedAt
      let leaseExpires = addUTCTime (fromIntegral claimLeaseSeconds) observedAt
      canned <- claimCannedMonitorFires owner observedAt leaseExpires claimBatchSize
      elaborated <- claimElaboratedMonitorFires owner observedAt leaseExpires claimBatchSize
      pure (map WorkCanned canned <> map WorkElaborated elaborated)

    processWork = \case
      WorkCanned fire -> process fire
      WorkElaborated fire ->
        dispatchElaborated fire `catchSync` \e ->
          logAttention "monitor: elaborated dispatch failed before turn admission" $
            object
              [ "fire_id" .= fire.emfFireId.unMonitorFireId,
                "error" .= T.pack (show e)
              ]

    process fire = do
      -- This lookup is the crash boundary. If canonical publication committed
      -- but acknowledgement did not, resume by acknowledging that same row.
      lookupMonitorFireOutput fire.cmfFireId >>= \case
        Just canonical -> advance fire (Just canonical)
        Nothing -> do
          outcome <-
            catchSync (deliver fire) $ \e ->
              pure (SendFailed (T.pack (show e)))
          case outcome of
            SentRecorded canonical -> advance fire (Just canonical)
            SentUnrecorded {} -> advance fire Nothing
            SendFailed err -> do
              -- Covers an ambiguous/concurrent publish: the unique provenance
              -- may have committed even when this caller observed an error.
              lookupMonitorFireOutput fire.cmfFireId >>= \case
                Just canonical -> advance fire (Just canonical)
                Nothing -> failDelivery fire err

    advance fire canonical = do
      completedAt <- liftIO getCurrentTime
      nextAt <- case fire.cmfCron of
        Nothing -> pure Nothing
        Just expression -> case parseCronSchedule expression of
          Right schedule -> pure (nextCronFire tz schedule completedAt)
          Left _ -> pure Nothing
      when (isJust fire.cmfCron && nextAt == Nothing) $
        logAttention "monitor: cannot advance cron; closing" $
          object
            [ "fire_id" .= fire.cmfFireId.unMonitorFireId,
              "monitor" .= fire.cmfMonitor.mrMonitorId.unMonitorId,
              "cron" .= fire.cmfCron
            ]
      accepted <- completeCannedMonitorFire owner fire.cmfFireId canonical nextAt
      if accepted
        then
          logInfo "monitor: canned fire dispatched" $
            object
              [ "fire_id" .= fire.cmfFireId.unMonitorFireId,
                "monitor" .= fire.cmfMonitor.mrMonitorId.unMonitorId,
                "recurring" .= isJust fire.cmfCron
              ]
        else
          logAttention "monitor: fire acknowledgement lost claim" $
            object ["fire_id" .= fire.cmfFireId.unMonitorFireId]

    failDelivery fire err = do
      now <- liftIO getCurrentTime
      let failedAttempt = fire.cmfDeliveryAttempts + 1
      case cannedRetryDecision now failedAttempt of
        RetryCannedAt retryAt -> do
          accepted <- recordMonitorFireFailure owner fire.cmfFireId err (Just retryAt)
          when accepted $
            logAttention "monitor: canned delivery retry scheduled" $
              object
                [ "fire_id" .= fire.cmfFireId.unMonitorFireId,
                  "attempt" .= failedAttempt,
                  "retry_at" .= retryAt,
                  "error" .= err
                ]
        ParkCanned -> do
          accepted <- recordMonitorFireFailure owner fire.cmfFireId err Nothing
          when accepted $
            logAttention "monitor: canned delivery parked" $
              object
                [ "fire_id" .= fire.cmfFireId.unMonitorFireId,
                  "attempts" .= failedAttempt,
                  "error" .= err
                ]

    deliver fire = do
      let groupId = GroupId fire.cmfGroupId
      body <- deliveryBody groupId (PrincipalId <$> fire.cmfAuthorPrincipalId) fire.cmfText
      sendRecorded
        OutboundRequest
          { orKind = KindChat,
            orGroupId = groupId,
            orBody = body,
            orReplyTo = Nothing,
            orDeliveryScope = DeliverConversation,
            orTurnOutput = Nothing,
            orMonitorFireId = Just fire.cmfFireId
          }

data MonitorWorkItem
  = WorkCanned !CannedMonitorFire
  | WorkElaborated !ElaboratedMonitorFire

deliveryBody ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  Maybe PrincipalId ->
  Text ->
  Eff es (Body 'Canonical)
deliveryBody groupId maybePrincipal body
  | isPrivateChat groupId = pure plain
  | otherwise = case maybePrincipal of
      Nothing -> pure plain
      Just principal -> do
        let GroupId conversation = groupId
        resolved <- resolveMentionIdentities conversation [principal]
        pure $ case Map.lookup principal resolved of
          Nothing -> plain
          Just identity ->
            Body
              [ NMention (MentionIdentity identity) (tshow principal.unPrincipalId),
                NText (" ⏰ 提醒：" <> body)
              ]
  where
    plain = Body [NText ("⏰ 提醒：" <> body)]
