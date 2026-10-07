-- | Host assembly for the destiny tools: binds the turn's author as the only
-- account a call can act as, attaches that person's token, refreshes it when
-- Bungie rejects it, and waits out Bungie's short throttles.
module Max.Destiny.ToolRuntime (destinyToolsWithRuntime) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (withMVar)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Effectful
import Effectful.Log (Log, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Max.Bungie.Account
import Max.Bungie.Api
import Max.Bungie.Client
import Max.Bungie.Definitions (kindAliases, resolveKind, unsignedHash)
import Max.Bungie.Manifest (SearchHit (..), lookupDefinitions, searchDefinitions)
import Max.Bungie.Runtime (BungieRuntime (..))
import Max.Bungie.Types (DestinyMembership (..))
import Max.Effects.Destiny
import Max.Effects.Tools (Tool, hoistTool)
import Max.ToolContext (ToolContext, toolAuthorPrincipalId)
import Max.Tools.Destiny (destinyToolsFor)

destinyToolsWithRuntime :: (WithConnection :> es, Log :> es, IOE :> es) => BungieRuntime -> ToolContext -> [Tool es]
destinyToolsWithRuntime runtime context =
  map (hoistTool (runDestiny account readCall writeCall lookupCall searchCall)) destinyToolsFor
  where
    principal = toolAuthorPrincipalId context

    account =
      accessTokenFor runtime principal >>= \case
        Right Nothing -> pure (object ["linked" .= False, "login" .= loginHint])
        Left problem -> pure (object ["linked" .= False, "login" .= problem])
        Right (Just (token, linked)) -> do
          characters <- case linked.laMembership of
            Nothing -> pure (Left "这个 Bungie 账号下没有命运2角色")
            Just membership ->
              liftIO (callBungie runtime.brHttp runtime.brConfig responseLimit (Just token) (profileTarget membership) Nothing) >>= \case
                Left failure -> pure (Left (renderBungieFailure failure))
                Right profile -> pure (Right (characterSummaries profile))
          pure . object $
            [ "linked" .= True,
              "bungie_name" .= linked.laBungieName,
              "membership_type" .= ((.dmType) <$> linked.laMembership),
              "membership_id" .= (T.pack . show . (.dmId) <$> linked.laMembership),
              "linked_at" .= linked.laLinkedAt,
              "relink_before" .= linked.laRefreshExpiresAt
            ]
              <> either (\e -> ["characters" .= ([] :: [Value]), "characters_error" .= e]) (\cs -> ["characters" .= cs]) characters

    readCall path query body fresh = case readTarget (isJust body) path query of
      Left err -> pure (Left err)
      Right target0 -> do
        -- Bungie caches responses by URL for minutes; a unique parameter
        -- reads the current state.
        target <-
          if fresh
            then (\now -> target0 {atQuery = target0.atQuery <> [("fresh", T.pack (show (floor (utcTimeToPOSIXSeconds now * 1000) :: Integer)))]}) <$> liftIO getCurrentTime
            else pure target0
        -- An unlinked or broken link still reads public data anonymously.
        token <- either (const Nothing) (fmap fst) <$> accessTokenFor runtime principal
        result <- withRetries token $ \bearer -> callBungie runtime.brHttp runtime.brConfig responseLimit bearer target body
        pure (either (Left . renderBungieFailure) Right result)

    writeCall path body = case writeTarget path of
      Left err -> pure (WriteRefused err)
      Right target ->
        accessTokenFor runtime principal >>= \case
          Right Nothing -> pure (WriteRefused loginHint)
          Left problem -> pure (WriteRefused problem)
          Right (Just (token, linked)) -> do
            logInfo "destiny: write" (object ["path" .= T.intercalate "/" target.atSegments, "account" .= linked.laBungieName])
            -- Bungie throttles item actions per account; one at a time.
            result <- withSeqEffToIO $ \run ->
              withMVar runtime.brWriteGate $ \() -> run $
                withRetries (Just token) $ \bearer -> callBungie runtime.brHttp runtime.brConfig responseLimit bearer target (Just body)
            pure $ case result of
              Right response -> WriteApplied response
              Left (BungieRefused e) -> WriteRefused (renderBungieError e)
              Left (BungieUnreachable detail) -> WriteUncertain ("请求结果未知，先用 destiny_read 核对再决定是否重试：" <> detail)

    -- One refresh when Bungie rejects a token that looked valid, and up to
    -- two waits when it asks for a short pause.
    withRetries token call = attempt (2 :: Int) token
      where
        attempt throttles bearer =
          liftIO (call bearer) >>= \case
            Left (BungieRefused e)
              | authExpired e,
                Just rejected <- bearer ->
                  refreshAfterRejection runtime principal rejected >>= \case
                    Right (fresh, _) | fresh /= rejected -> liftIO (call (Just fresh))
                    _ -> pure (Left (BungieRefused e))
              | throttled e,
                throttles > 0,
                e.beThrottleSeconds <= 10 -> do
                  liftIO (threadDelay (max 1 e.beThrottleSeconds * 1_000_000))
                  attempt (throttles - 1) bearer
            other -> pure other

    lookupCall rawKind hashes = case resolveKind rawKind of
      Left err -> pure (Left err)
      Right kind -> case traverse unsignedHash hashes of
        Nothing -> pure (Left "hash 超出 32 位范围")
        Just normalized -> do
          (found, missing) <- lookupDefinitions runtime kind normalized
          pure . Right $
            object
              [ "kind" .= kind,
                "definitions" .= Object (KeyMap.fromList [(Key.fromText (T.pack (show h)), v) | (h, v) <- Map.toList found]),
                "missing" .= missing
              ]

    searchCall rawKind term limit = case traverse resolveKind rawKind of
      Left err -> pure (Left err)
      Right kind ->
        searchDefinitions kind term limit >>= \case
          Nothing -> pure (Left ("本地 manifest 还在同步，暂时不能按名字搜；物品可先用 destiny_read 的 /Destiny2/Armory/Search/DestinyInventoryItemDefinition/" <> term <> "/"))
          Just hits -> pure (Right (object ["query" .= term, "results" .= map hitSummary hits]))

-- Generous: a whole profile with every component is tens of megabytes. The
-- tool reports oversize responses instead of returning them.
responseLimit :: Int
responseLimit = 64 * 1024 * 1024

loginHint :: Text
loginHint = "还没有绑定 Bungie 账号：让对方私聊我发送 !destiny login，在浏览器里用 Bungie（Steam/PSN/Xbox 等）登录并批准即可，不需要任何 API key。"

profileTarget :: DestinyMembership -> ApiTarget
profileTarget membership =
  ApiTarget MainHost ["Destiny2", T.pack (show membership.dmType), "Profile", T.pack (show membership.dmId)] [("components", "200")]

characterSummaries :: Value -> [Value]
characterSummaries profile = case at ["characters", "data"] profile of
  Just (Object characters) ->
    map snd . sortOn (Down . fst) $
      mapMaybe summary (KeyMap.elems characters)
  _ -> []
  where
    summary character = do
      ident <- textField "characterId" character
      let lastPlayed = textField "dateLastPlayed" character
      pure
        ( lastPlayed,
          object
            [ "character_id" .= ident,
              "class" .= className (intField "classType" character),
              "light" .= intField "light" character,
              "last_played" .= lastPlayed,
              "minutes_played" .= (readInt =<< textField "minutesPlayedTotal" character)
            ]
        )
    className = \case
      Just 0 -> "泰坦" :: Text
      Just 1 -> "猎人"
      Just 2 -> "术士"
      _ -> "未知"
    readInt t = case reads (T.unpack t) :: [(Int64, String)] of
      [(n, "")] -> Just n
      _ -> Nothing

hitSummary :: SearchHit -> Value
hitSummary hit =
  object $
    [ "kind" .= maybe hit.shKind fst (lookupAlias hit.shKind),
      "hash" .= hit.shHash,
      "name" .= hit.shName
    ]
      <> ["name_en" .= hit.shNameEn | not (T.null hit.shNameEn)]
      <> [key .= v | key <- ["type", "tier", "classType", "itemType"], Just v <- [at [Key.toText key] hit.shData]]
      <> ["description" .= T.take 100 d | Just (String d) <- [at ["description"] hit.shData]]
  where
    lookupAlias kind = case filter ((== kind) . snd) kindAliases of
      alias : _ -> Just alias
      [] -> Nothing

at :: [Text] -> Value -> Maybe Value
at [] value = Just value
at (key : rest) (Object o) = KeyMap.lookup (Key.fromText key) o >>= at rest
at _ _ = Nothing

textField :: Text -> Value -> Maybe Text
textField key value = case at [key] value of
  Just (String t) -> Just t
  _ -> Nothing

intField :: Text -> Value -> Maybe Int
intField key value = case at [key] value of
  Just (Number n) -> Just (round n)
  _ -> Nothing
