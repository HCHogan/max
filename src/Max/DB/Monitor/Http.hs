module Max.DB.Monitor.Http (armHttpMonitor, receiveHttpMonitor) where

import Control.Monad (void)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (String), object, (.=))
import Data.ByteArray (constEq)
import Data.ByteString.Base16 qualified as Base16
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Codec (databaseNow, jsonText)
import Max.DB.ConversationLock (lockConversation)
import Max.DB.Monitor (armElaboratedMonitor)
import Max.DB.Monitor.Occurrence
import Max.DB.Transaction (withTransaction)
import Max.Hash (jsonHash)
import Max.Monitor.Control (HttpMonitorSpec (..), MonitorArmError)
import Max.Monitor.Types
import Max.Node.Routing (OccurrenceRoute (..))
import Max.Platform.Types (PrincipalId)
import Max.Task.Types (profileName)
import Max.Turn.Types (AgentTurnRef)
import OneBot.Types (GroupId)

armHttpMonitor ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  PrincipalId ->
  AgentTurnRef ->
  Map Text Text ->
  HttpMonitorSpec ->
  Eff es (Either MonitorArmError HttpMonitorRegistration)
armHttpMonitor group actor turn grants spec = withTransaction $ do
  hook <- liftIO (UUID.toText <$> UUID.nextRandom)
  token <- liftIO (TE.decodeUtf8 . Base16.encode <$> getRandomBytes 32)
  let trigger = object ["kind" .= ("Http" :: Text), "version" .= (1 :: Int), "hook" .= hook]
  armed <- armElaboratedMonitor group actor turn spec.goal "http" trigger Nothing Nothing spec.cooldownSeconds spec.expiresAt spec.maxFires grants
  case armed of
    Left failure -> pure (Left failure)
    Right monitor -> do
      void $
        execute
          "INSERT INTO monitor_http_hooks(monitor_id,hook_id,token_sha256) VALUES(?,?,?)"
          (monitor.mrMonitorId, hook, jsonHash (String token))
      void $
        execute
          "UPDATE monitors SET task_profile=?,change_only=false WHERE monitor_id=?"
          (profileName spec.profile, monitor.mrMonitorId)
      pure (Right (HttpMonitorRegistration monitor ("/hooks/" <> hook) token))

-- Event data cannot select the goal, conversation or grants. Ordinary task
-- admission rechecks the monitor owner's current authority.
receiveHttpMonitor ::
  (WithConnection :> es, IOE :> es) =>
  Text -> Text -> Maybe Text -> Value -> Eff es HttpMonitorResult
receiveHttpMonitor hook token eventId payload = withTransaction $ do
  hooks <-
    query
      "SELECT h.monitor_id,c.legacy_group_id,h.token_sha256 FROM monitor_http_hooks h\
      \ JOIN monitors m USING(monitor_id) JOIN conversations c USING(conversation_id) WHERE hook_id=?"
      (Only hook)
  case hooks :: [(MonitorId, Int64, Text)] of
    [(identifier, group, expected)]
      | constEq (TE.encodeUtf8 expected) (TE.encodeUtf8 (jsonHash (String token))) -> do
          _ <- lockConversation group
          definition <- loadDefinition identifier
          now <- databaseNow
          case definition of
            Just current
              | current.active && maybe True (> now) current.expires ->
                  accept current now
            _ -> pure HttpGone
    _ -> pure HttpUnauthorized
  where
    accept definition now = do
      let explicitKey = ("http:event:" <>) . jsonHash . String <$> eventId
      duplicates <- case explicitKey of
        Just key ->
          query
            "SELECT EXISTS(SELECT 1 FROM monitor_fires WHERE monitor_id=? AND idempotency_key=?)"
            (definition.monitorId, key)
        Nothing ->
          query
            "SELECT EXISTS(SELECT 1 FROM monitor_fires WHERE monitor_id=? AND trigger_payload=?::jsonb\
            \ AND created_at>now()-interval '5 minutes')"
            (definition.monitorId, jsonText payload)
      if duplicates == [Only True]
        then pure HttpDuplicate
        else do
          limits <-
            query
              "SELECT status='armed' AND (max_fire_count IS NULL OR fire_count<max_fire_count), cooldown_until IS NULL OR cooldown_until<=? FROM monitors WHERE monitor_id=?"
              (now, definition.monitorId)
          case limits :: [(Bool, Bool)] of
            [(False, _)] -> pure HttpGone
            [(True, False)] -> pure HttpBusy
            [(True, True)] -> do
              key <- maybe (liftIO (("http:" <>) . UUID.toText <$> UUID.nextRandom)) pure explicitKey
              prepared <- prepareOccurrenceWithin definition (OccurrenceDraft key now Nothing "HTTP webhook event (untrusted external data)" (Just payload) True)
              case occurrenceRoute prepared of
                -- Retriable ingress declines before consuming the key or budget.
                -- Durable producers persist this same routing decision instead.
                RecordOverflow _ -> pure HttpBusy
                _ -> do
                  inserted <- insertPreparedOccurrenceWithin prepared
                  if isJust inserted
                    then do
                      void $
                        execute
                          "UPDATE monitors SET fire_count=fire_count+1,cooldown_until=?::timestamptz+cooldown_seconds*interval '1 second',\
                          \ status=CASE WHEN fire_count+1>=max_fire_count THEN 'expired' ELSE status END,\
                          \ status_reason=CASE WHEN fire_count+1>=max_fire_count THEN 'max_fire_count' ELSE status_reason END,\
                          \ updated_at=now() WHERE monitor_id=?"
                          (now, definition.monitorId)
                      pure HttpAccepted
                    else pure HttpDuplicate
            _ -> pure HttpGone
