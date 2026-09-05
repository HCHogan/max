{-# LANGUAGE RecordWildCards #-}

module Max.MaxOps.Notifications
  ( NotificationConfig (..),
    Alert (..),
    parseAlerts,
    alertKey,
    renderAlert,
    validateNotificationConfig,
    enqueueAlerts,
    notificationApplication,
    notificationServer,
  )
where

import Control.Concurrent.STM
import Control.Exception (finally, throwIO)
import Control.Monad (forM, replicateM_, unless)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteArray (constEq)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Char (isAlphaNum, isControl)
import Data.Int (Int64)
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful
import Effectful.Log (Log, logAttention, logInfo)
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Transaction (withTransaction)
import Max.IR (Body (..), Node (..))
import Max.Platform.Store (OutboundDraft (..), enqueueOutboundInTransaction)
import Max.Util (trySync, trySyncIO)
import Network.HTTP.Types
import Network.Wai
import Network.Wai.Handler.Warp qualified as Warp
import System.FilePath (isAbsolute)
import System.Timeout (timeout)

data NotificationConfig = NotificationConfig
  { ncHost :: !Text,
    ncPort :: !Int,
    ncTokenFile :: !FilePath,
    ncGroups :: ![Int64],
    ncHosts :: ![Text]
  }
  deriving stock (Eq, Show)

data Alert = Alert
  { alertStatus :: !Text,
    alertLabels :: !(Map Text Text),
    alertAnnotations :: !(Map Text Text),
    alertStartsAt :: !UTCTime,
    alertEndsAt :: !(Maybe UTCTime)
  }
  deriving stock (Eq, Show)

validateNotificationConfig :: NotificationConfig -> [Text]
validateNotificationConfig config =
  ["maxops_notifications.host" | config.ncHost `notElem` ["127.0.0.1", "::1"]]
    <> ["maxops_notifications.port" | config.ncPort < 1 || config.ncPort > 65535]
    <> ["maxops_notifications.token_file" | not (isAbsolute config.ncTokenFile) || "/nix/store/" `T.isPrefixOf` T.pack config.ncTokenFile]
    <> ["maxops_notifications.groups" | null config.ncGroups || any (<= 0) config.ncGroups || length config.ncGroups > 10]
    <> ["maxops_notifications.hosts" | null config.ncHosts || any (\host -> T.null host || T.length host > 128 || not (T.all (\character -> isAlphaNum character || character `elem` ("_-" :: String)) host)) config.ncHosts]

parseAlerts :: [Text] -> Value -> Either String [Alert]
parseAlerts hosts = parseEither $ withObject "Alertmanager webhook" $ \payload -> do
  version <- payload .: "version"
  unless (version == ("4" :: Text)) (fail "invalid version")
  status <- payload .: "status"
  unless (status `elem` (["firing", "resolved"] :: [Text])) (fail "invalid status")
  values <- payload .: "alerts" :: Parser [Value]
  unless (length values <= 100) (fail "too many alerts")
  alerts <- traverse (withObject "alert" parseAlert) values
  pure [alert | alert <- alerts, Map.lookup "instance" alert.alertLabels `elem` map Just hosts]
  where
    parseAlert value = do
      alertStatus <- value .: "status"
      unless (alertStatus `elem` ["firing", "resolved"]) (fail "invalid alert status")
      alertLabels <- value .: "labels"
      unless (maybe False (not . T.null) (Map.lookup "alertname" alertLabels)) (fail "missing alert name")
      alertAnnotations <- value .:? "annotations" .!= Map.empty
      alertStartsAt <- value .: "startsAt"
      alertEndsAt <- value .:? "endsAt"
      unless (alertStatus /= "resolved" || maybe False (>= alertStartsAt) alertEndsAt) (fail "invalid resolution time")
      pure Alert {..}

alertKey :: Alert -> Text
alertKey alert = TE.decodeUtf8 . Base16.encode . SHA256.hash . LBS.toStrict $ encode (alert.alertLabels, alert.alertStartsAt, alert.alertStatus, if alert.alertStatus == "resolved" then alert.alertEndsAt else Nothing)

renderAlert :: Alert -> Text
renderAlert alert =
  T.intercalate "\n" $
    [ "[fleet " <> (if alert.alertStatus == "firing" then "告警" else "恢复") <> "] " <> field 128 "instance" alert.alertLabels <> " · " <> field 160 "alertname" alert.alertLabels,
      "级别：" <> field 32 "severity" alert.alertLabels,
      field 300 "summary" alert.alertAnnotations,
      field 500 "description" alert.alertAnnotations,
      "开始：" <> T.pack (show alert.alertStartsAt)
    ]
      <> ["恢复：" <> T.pack (show ended) | alert.alertStatus == "resolved", ended <- maybe [] pure alert.alertEndsAt]
  where
    field limit key values = T.take limit (T.map (\character -> if isControl character then ' ' else character) (Map.findWithDefault "" key values))

enqueueAlerts :: (WithConnection :> es, IOE :> es) => [Int64] -> [Alert] -> Eff es Int
enqueueAlerts groups alerts = withTransaction $ do
  _ <- execute "SET LOCAL statement_timeout = '5s'" ()
  _ <- execute "SET LOCAL lock_timeout = '2s'" ()
  _ <- execute "DELETE FROM maxops_notifications WHERE (group_id, alert_key) IN (SELECT group_id, alert_key FROM maxops_notifications WHERE last_notified_at < now() - interval '30 days' LIMIT 1000)" ()
  counts <- forM [(group, alert) | group <- nub groups, alert <- alerts] $ \(group, alert) -> do
    inserted <-
      query
        "INSERT INTO maxops_notifications (group_id, alert_key) VALUES (?, ?) ON CONFLICT (group_id, alert_key) DO UPDATE SET last_notified_at=now() WHERE maxops_notifications.last_notified_at <= now() - interval '4 hours' RETURNING alert_key"
        (group, alertKey alert)
    if null (inserted :: [Only Text])
      then pure 0
      else do
        _ <-
          enqueueOutboundInTransaction
            OutboundDraft
              { legacyConversationId = group,
                transcriptKind = "command",
                sourceCanonicalMessageId = Nothing,
                canonicalBody = Body [NText (renderAlert alert)],
                replyToCanonicalMessageId = Nothing,
                turnOutputLink = Nothing,
                monitorFireId = Nothing
              }
        pure 1
  pure (sum counts)

notificationApplication :: NotificationConfig -> ([Alert] -> IO Int) -> IO Application
notificationApplication config accept = do
  slots <- newTBQueueIO 4
  atomically (replicateM_ 4 (writeTBQueue slots ()))
  pure $ \request respond -> do
    if requestMethod request /= methodPost || pathInfo request /= ["v1", "alerts"]
      then respond (reply status404 "not found")
      else do
        credential <- trySyncIO (BS.readFile config.ncTokenFile)
        let authorized = case (credential, [header | (name, header) <- requestHeaders request, name == hAuthorization]) of
              (Right bytes, [header]) ->
                let token = BS8.dropWhileEnd (`elem` ['\r', '\n']) bytes
                 in BS.length token >= 32 && BS.length token <= 512 && BS.all (\byte -> byte >= 33 && byte <= 126) token && constEq header ("Bearer " <> token)
              _ -> False
        if not authorized
          then respond (reply status401 "unauthorized")
          else do
            acquired <- atomically (tryReadTBQueue slots)
            case acquired of
              Nothing -> respond (reply status503 "busy; retry")
              Just () ->
                finally
                  ( do
                      response <- timeout 6_000_000 (process request)
                      respond (fromMaybe (reply status503 "notification deadline exceeded; retry") response)
                  )
                  (atomically (writeTBQueue slots ()))
  where
    process request = do
      body <- readBounded request [] 0
      case body of
        Nothing -> pure (reply status413 "payload too large")
        Just bytes -> case eitherDecodeStrict' bytes >>= parseAlerts config.ncHosts of
          Left _ -> pure (reply status400 "invalid Alertmanager webhook")
          Right alerts ->
            trySyncIO (accept alerts) >>= \case
              Left _ -> pure (reply status503 "notification not durably accepted; retry")
              Right count -> pure (responseLBS status202 [(hContentType, "application/json")] (encode (object ["queued" .= count])))
    reply status message = responseLBS status [(hContentType, "application/json")] (encode (object ["error" .= (message :: Text)]))
    readBounded request chunks size = do
      chunk <- getRequestBodyChunk request
      if size + BS.length chunk > 256 * 1024
        then pure Nothing
        else if BS.null chunk then pure (Just (BS.concat (reverse chunks))) else readBounded request (chunk : chunks) (size + BS.length chunk)

notificationServer :: (WithConnection :> es, Log :> es, IOE :> es) => NotificationConfig -> Eff es ()
notificationServer config = withEffToIO (ConcUnlift Ephemeral Unlimited) $ \run -> do
  application <- notificationApplication config $ \alerts -> run $ do
    outcome <- trySync (enqueueAlerts config.ncGroups alerts)
    case outcome of
      Left failure -> do
        logAttention "maxops: notification enqueue failed; sender must retry" (object ["alerts" .= length alerts])
        liftIO (throwIO failure)
      Right count -> do
        logInfo "maxops: notifications durably accepted" (object ["queued" .= count, "alerts" .= length alerts])
        pure count
  Warp.runSettings (Warp.setHost (fromString (T.unpack config.ncHost)) (Warp.setPort config.ncPort Warp.defaultSettings)) application
