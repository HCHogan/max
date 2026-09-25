module Max.Monitor.Dispatch
  ( dispatchMonitorFire,
  )
where

import Control.Monad (void, when)
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Log (Log, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Command.Permission
  ( PermTier (TierGroupAdmin, TierOwner),
    tierSatisfied,
  )
import Max.DB.Monitor
  ( ElaboratedMonitorFire (..),
    expireElaboratedMonitorFire,
  )
import Max.DB.Monitor.Admission qualified as MonitorJob
import Max.DB.Transaction (withTransaction)
import Max.Dispatch
  ( DispatchMessage (authorPrincipalId, canonicalId, groupId),
  )
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Env (BotEnv (..))
import Max.Handler.Access (effectiveTierKnown)
import Max.Jobs qualified as Jobs
import Max.Monitor (nextCronFire)
import Max.Monitor.Types
  ( MonitorDispatchResult (..),
    MonitorRef (..),
    monitorHandleText,
  )
import Max.Platform.Store.Ingest (loadDispatchMessage)
import Max.Platform.Types
  ( CanonicalMessageId (unCanonicalMessageId),
    noAdvertisedCaps,
  )
import Max.Task.State qualified as JobState
import Max.Task.Types (JobResult (JobResult), taskGrants)
import Max.Tool.Types (ToolDefinition (..), ToolRef (..))
import Max.ToolContext
  ( TurnCapabilities (..),
  )
import Max.Toolset (toolDefinitionsFor)
import Max.Turn.Continuity (toolCatalogFingerprint)
import OneBot.Types (GroupId (GroupId))
import System.Cron.Parser (parseCronSchedule)

dispatchMonitorFire ::
  ( Log :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  ElaboratedMonitorFire ->
  Eff es MonitorDispatchResult
dispatchMonitorFire fire = do
  seedClaim <- maybe (pure Nothing) loadDispatchMessage fire.emfSeedCanonicalMessage
  case seedClaim of
    Nothing -> expire "arming principal no longer has an inbound dispatch seed"
    Just seed -> do
      if seed.groupId /= GroupId fire.emfGroupId || seed.authorPrincipalId /= fire.emfArmedByPrincipal
        then expire "arming principal provenance no longer resolves in this conversation"
        else do
          env :: BotEnv <- ask
          tier <- effectiveTierKnown env seed.groupId seed
          case tier of
            -- A disconnected platform is not evidence of revoked authority.
            -- The scheduler defers this trigger without blocking other work.
            Nothing -> pure MonitorRecheck
            Just actual
              | not (roleStillAllows fire.emfRequiredRole actual) ->
                  expire "arming principal role no longer permits monitors"
            Just _ -> do
              now <- liftIO getCurrentTime
              nextAt <- case fire.emfCron of
                Nothing -> pure (Right Nothing)
                Just expression -> case parseCronSchedule expression of
                  Left err -> pure (Left ("invalid persisted cron: " <> T.pack err))
                  Right schedule -> pure (Right (nextCronFire env.beTimeZone schedule now))
              case nextAt of
                Left err -> expire err
                Right maybeNext -> do
                  profile <- MonitorJob.monitorTaskProfile fire.emfFireId
                  let caps =
                        TurnCapabilities
                          { tcMultimodal = True,
                            tcStickers = False,
                            tcSkills = True,
                            tcOutput = noAdvertisedCaps,
                            tcMonitorArming = False,
                            tcCatalogGrants = Map.empty,
                            tcEffectCeiling = Just fire.emfEffectToolGrants,
                            tcBackground = False
                          }
                      current = Map.fromList [(definition.tdRef.unToolRef, toolCatalogFingerprint [definition]) | definition <- toolDefinitionsFor env seed.groupId caps]
                  admitted <- withTransaction (MonitorJob.admitMonitorTaskWithin fire.emfFireId maybeNext (taskGrants profile current) seed.canonicalId.unCanonicalMessageId)
                  case admitted of
                    Right (MonitorJob.MonitorTaskAdmitted identifier spec) -> do
                      result <- liftIO (Jobs.admitJob env.beJobs Nothing identifier spec)
                      for_ (either Just (const Nothing) result) $ \detail -> do
                        void (MonitorJob.recordMonitorResult fire.emfFireId JobState.Failed (JobResult detail Nothing))
                        logAttention "monitor job rejected" (object ["error" .= detail])
                    Left MonitorJob.MonitorHourlyBudget -> pure ()
                    Left detail -> void (expire (T.pack (show detail)))
                    _ -> pure ()
                  pure MonitorHandled
  where
    expire reason = do
      expired <- expireElaboratedMonitorFire fire.emfFireId reason
      when expired $
        logAttention "monitor: elaborated fire expired at revalidation" $
          object
            [ "monitor" .= monitorHandleText fire.emfMonitor.mrMonitorOrdinal,
              "reason" .= reason
            ]
      pure MonitorHandled

roleStillAllows :: T.Text -> PermTier -> Bool
roleStillAllows required actual = case required of
  "member" -> True
  "owner" -> tierSatisfied TierOwner actual
  "group_admin" -> tierSatisfied TierGroupAdmin actual
  _ -> False
