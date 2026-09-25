module Max.Browser.Profile (browserCommand, browserCommandOnce, filterProfileState) where

import Control.Monad (forM_, void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromRight)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as Vector
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.Browser.Registry
import Max.Browser.Runtime (exportJobBrowser, ownedJobBrowser, profileIdentity, resetTaskBrowser, revokeProfileBrowsers)
import Max.Browser.Vault (sealBrowserState)
import Max.DB.Transaction (withTransaction)
import Max.Jobs (Jobs)
import Max.Monitor.Types (MonitorOrdinal (..), parseMonitorHandle)
import Max.Platform.Types
  ( CanonicalMessageId (..),
    PrincipalId (..),
  )
import Max.Task.Types (parseTaskHandle)
import Network.URI (URI (..), URIAuth (..), parseURI)
import OneBot.Types (GroupId (..))

browserCommandOnce :: (WithConnection :> es, IOE :> es) => Jobs -> BrowserRegistry -> GroupId -> PrincipalId -> CanonicalMessageId -> [Text] -> Eff es Value
browserCommandOnce jobs registry group@(GroupId groupId) actor@(PrincipalId principal) (CanonicalMessageId message) pieces = do
  claimed <- execute "INSERT INTO browser_command_receipts(message_id) SELECT canonical_message_id FROM messages JOIN conversations USING(conversation_id) WHERE canonical_message_id=? AND author_principal_id=? AND legacy_group_id=? ON CONFLICT DO NOTHING" (message, principal, groupId)
  if claimed == 1
    then do
      outcome <- browserCommand jobs registry group actor pieces
      let result = either (\detail -> object ["error" .= detail]) id outcome
      void $ execute "UPDATE browser_command_receipts SET result=?::jsonb WHERE message_id=?" (TE.decodeUtf8 (LBS.toStrict (encode result)), message)
      pure result
    else do
      rows <- query "SELECT receipt.result::text FROM browser_command_receipts receipt JOIN messages ON canonical_message_id=receipt.message_id JOIN conversations USING(conversation_id) WHERE receipt.message_id=? AND author_principal_id=? AND legacy_group_id=?" (message, principal, groupId)
      pure $ case rows of
        [Only (Just encoded)] -> fromRight unavailable (eitherDecodeStrict' (TE.encodeUtf8 encoded))
        _ -> unavailable
  where
    unavailable = object ["error" .= ("browser command is in progress, interrupted, or its source is invalid; inspect current state before issuing a new command. It was not replayed" :: Text)]

filterProfileState :: Text -> Value -> Either Text Value
filterProfileState origin payload = do
  uri <- maybe (Left "profile origin must be an HTTPS origin without credentials, path or query") Right (parseURI (T.unpack origin))
  authority <- maybe (Left "profile origin has no host") Right uri.uriAuthority
  if uri.uriScheme /= "https:" || not (null authority.uriUserInfo) || uri.uriPath `notElem` ["", "/"] || not (null uri.uriQuery && null uri.uriFragment)
    then Left "profile origin must be an HTTPS origin without credentials, path or query"
    else do
      (cookies, origins) <-
        either (const (Left "invalid browser storage checkpoint")) Right $
          parseEither (withObject "checkpoint" $ \root -> root .: "storage" >>= withObject "storage" (\fields -> (,) <$> fields .: "cookies" <*> fields .: "origins")) payload
      let hostname = T.toLower (T.pack authority.uriRegName)
          canonical = "https://" <> hostname <> T.pack authority.uriPort
          cookieForSite (Object fields) = case KeyMap.lookup "domain" fields of
            Just (String rawDomain)
              | let domain = T.dropWhile (== '.') (T.toLower rawDomain),
                not (T.null domain),
                hostname == domain || ("." <> domain) `T.isSuffixOf` hostname ->
                  Just (Object (KeyMap.insert "domain" (String hostname) fields))
            _ -> Nothing
          cookieForSite _ = Nothing
          originForSite (Object fields) = KeyMap.lookup "origin" fields == Just (String canonical)
          originForSite _ = False
      pure (object ["storage" .= object ["cookies" .= Vector.mapMaybe cookieForSite cookies, "origins" .= Vector.filter originForSite origins]])

browserCommand :: forall es. (WithConnection :> es, IOE :> es) => Jobs -> BrowserRegistry -> GroupId -> PrincipalId -> [Text] -> Eff es (Either Text Value)
browserCommand jobs registry group@(GroupId groupId) actor@(PrincipalId principal) pieces = do
  result <- runCommand
  case (result, pieces) of
    (Right _, operation : remaining) -> do
      let task = case remaining of handle : _ -> parseTaskHandle handle; _ -> Nothing
      void $ execute "INSERT INTO browser_command_events(conversation_id,principal_id,operation,task_id) SELECT conversation_id,?,?,? FROM conversations WHERE legacy_group_id=?" (principal, operation, task, groupId)
    _ -> pure ()
  pure result
  where
    runCommand = case pieces of
      ["reset", handle] | Just identifier <- parseTaskHandle handle -> resetTaskBrowser jobs registry group actor identifier Nothing
      ["profiles"] -> do
        rows <- query "SELECT name,origin,version,revoked FROM browser_profiles JOIN conversations USING(conversation_id) WHERE legacy_group_id=? AND principal_id=? ORDER BY name" (groupId, principal)
        pure (Right (toJSON [object ["name" .= (name :: Text), "origin" .= (origin :: Text), "version" .= (version :: Int64), "revoked" .= (revoked :: Bool)] | (name, origin, version, revoked) <- rows]))
      ["save", handle, name, origin]
        | Just identifier <- parseTaskHandle handle,
          validName name -> do
            saved <- ownedJobBrowser jobs registry group actor identifier $ \_ -> do
              exported <- exportJobBrowser registry identifier
              case exported >>= filterProfileState origin of
                Left detail -> pure (Left detail)
                Right state -> withTransaction $ do
                  raise lockConversation
                  profiles <-
                    query
                      "INSERT INTO browser_profiles(conversation_id,principal_id,name,origin) SELECT conversation_id,?,?,? FROM conversations WHERE legacy_group_id=? ON CONFLICT(conversation_id,principal_id,name) DO UPDATE SET origin=EXCLUDED.origin,version=browser_profiles.version+1,revoked=false,updated_at=clock_timestamp() RETURNING profile_id"
                      (principal, name, origin, groupId)
                  case profiles of
                    [Only profile] -> do
                      encrypted <- liftIO (sealBrowserState (browserVault registry) (profileIdentity profile) state)
                      void $ execute "UPDATE browser_profiles SET checkpoint=? WHERE profile_id=?" (encrypted, profile)
                      pure (Right profile)
                    _ -> pure (Left "profile save failed")
            case saved of
              Left detail -> pure (Left detail)
              Right profile -> do
                liftIO (revokeProfileBrowsers registry profile)
                pure (Right (object ["saved" .= name, "origin" .= origin]))
      ["use", handle, name] | Just identifier <- parseTaskHandle handle -> do
        profiles <- lookupProfile name
        case profiles of
          [binding] -> resetTaskBrowser jobs registry group actor identifier (Just binding)
          _ -> pure (Left "active profile not found for this owner and conversation")
      ["delete", name] -> do
        changed <- withTransaction $ do
          raise lockConversation
          query "UPDATE browser_profiles SET revoked=true,checkpoint=NULL,version=version+1,updated_at=clock_timestamp() WHERE principal_id=? AND name=? AND conversation_id=(SELECT conversation_id FROM conversations WHERE legacy_group_id=?) RETURNING profile_id" (principal, name, groupId)
        forM_ (changed :: [Only Int64]) $ \(Only profile) -> liftIO (revokeProfileBrowsers registry profile)
        pure (Right (object ["revoked" .= length changed]))
      ["unmonitor", handle] | Just ordinal <- parseMonitorHandle handle -> withTransaction $ do
        raise lockConversation
        removed <- query "DELETE FROM browser_monitor_profiles binding USING monitors,conversations WHERE binding.monitor_id=monitors.monitor_id AND monitors.conversation_id=conversations.conversation_id AND legacy_group_id=? AND armed_by_principal_id=? AND monitor_ordinal=? RETURNING binding.monitor_id" (groupId, principal, ordinal.unMonitorOrdinal)
        case removed of
          [Only (monitor :: Int64)] -> do
            void $ execute "UPDATE monitors SET definition_revision=definition_revision+1 WHERE monitor_id=?" (Only monitor)
            pure (Right (object ["monitor" .= handle, "profile_detached" .= True]))
          _ -> pure (Left "owned monitor profile binding not found")
      ["monitor", handle, name] | Just ordinal <- parseMonitorHandle handle -> withTransaction $ do
        raise lockConversation
        monitors <- query "SELECT monitor_id FROM monitors JOIN conversations USING(conversation_id) WHERE legacy_group_id=? AND armed_by_principal_id=? AND monitor_ordinal=? AND task_profile='browser' AND continuation_kind='elaborated' AND status='armed' FOR UPDATE OF monitors" (groupId, principal, ordinal.unMonitorOrdinal)
        profiles <- raise (lookupProfile name)
        case (monitors, profiles) of
          ([Only (monitor :: Int64)], [(profile, version)]) -> do
            void $ execute "INSERT INTO browser_monitor_profiles(monitor_id,profile_id,profile_version) VALUES(?,?,?) ON CONFLICT(monitor_id) DO UPDATE SET profile_id=EXCLUDED.profile_id,profile_version=EXCLUDED.profile_version" (monitor, profile, version)
            void $ execute "UPDATE monitors SET definition_revision=definition_revision+1 WHERE monitor_id=?" (Only monitor)
            pure (Right (object ["monitor" .= handle, "profile" .= name, "applies_to" .= ("future occurrences only; existing snapshots unchanged" :: Text)]))
          _ -> pure (Left "owned browser monitor or active profile not found")
      _ -> pure (Left "用法：!browser profiles | reset agent#N | save agent#N 名称 https://站点 | use agent#N 名称 | delete 名称 | monitor m#N 名称 | unmonitor m#N。reset/use 确认不重放旧操作；仅发起者可用。")
    validName name = not (T.null name) && T.length name <= 80
    lookupProfile :: Text -> Eff es [(Int64, Int64)]
    lookupProfile name =
      query
        "SELECT profile_id,version FROM browser_profiles JOIN conversations USING(conversation_id) WHERE legacy_group_id=? AND principal_id=? AND name=? AND NOT revoked AND checkpoint IS NOT NULL"
        (groupId, principal, name)
    lockConversation = void (query "SELECT conversation_id FROM conversations WHERE legacy_group_id=? FOR UPDATE" (Only groupId) :: Eff es [Only Int64])
