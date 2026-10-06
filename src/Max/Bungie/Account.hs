-- | A person's Bungie account link: browser login, token storage and refresh.
--
-- Authority is the principal. A login link is bound to whoever asked for it,
-- and tool calls only ever use the token of the turn's own author, so a model
-- cannot act on someone else's account. The link is delivered privately
-- because whoever completes it binds *their* Bungie account to the asker.
module Max.Bungie.Account
  ( LinkedAccount (..),
    LoginOutcome (..),
    loginStateTtlMinutes,
    beginLogin,
    completeLogin,
    linkedAccount,
    unlinkAccount,
    accessTokenFor,
    refreshAfterRejection,

    -- * Exposed for tests
    sealTokens,
  )
where

import Control.Concurrent.MVar (withMVar)
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.Random (getRandomBytes)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.ByteString.Base16 qualified as Base16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.Browser.Vault (openBrowserState, sealBrowserState)
import Max.Bungie.Api (ApiHost (..), ApiTarget (..))
import Max.Bungie.Client
import Max.Bungie.Runtime (BungieRuntime (..))
import Max.Bungie.Types
import Max.DB.Bungie
import Max.Platform.Types (PrincipalId (..))
import Max.Util (tshow)

data LinkedAccount = LinkedAccount
  { laBungieName :: !Text,
    laMembership :: !(Maybe DestinyMembership),
    laLinkedAt :: !UTCTime,
    laRefreshExpiresAt :: !UTCTime
  }
  deriving stock (Show, Eq)

data LoginOutcome = LoginOutcome
  { loRequester :: !Text,
    loAccount :: !AccountIdentity
  }
  deriving stock (Show, Eq)

loginStateTtlMinutes :: Int
loginStateTtlMinutes = 15

-- | Mint a single-use login link bound to @principal@. Only the state's
-- SHA-256 is stored.
beginLogin :: (WithConnection :> es, IOE :> es) => BungieRuntime -> PrincipalId -> Text -> Eff es Text
beginLogin runtime principal requester = do
  state <- liftIO (TE.decodeUtf8 . Base16.encode <$> getRandomBytes 32)
  now <- liftIO getCurrentTime
  insertLoginState (stateHash state) principal (T.take 64 requester) (addUTCTime (fromIntegral (loginStateTtlMinutes * 60)) now)
  pure (authorizeUrl runtime.brConfig state)

-- | Finish the browser round trip: consume the state, exchange the code,
-- identify the account, and store the sealed tokens.
completeLogin :: (WithConnection :> es, IOE :> es) => BungieRuntime -> Text -> Text -> Eff es (Either Text LoginOutcome)
completeLogin runtime state code =
  takeLoginState (stateHash state) >>= \case
    Nothing -> pure (Left "这个登录链接已失效或已经用过了。回到聊天里重新发 !destiny login 拿新链接。")
    Just (principal, requester) ->
      liftIO (exchangeAuthorizationCode runtime.brHttp runtime.brConfig code) >>= \case
        Left failure -> pure (Left failure)
        Right grant -> do
          identity <- liftIO (callBungie runtime.brHttp runtime.brConfig 1_000_000 (Just grant.tgAccessToken) membershipsTarget Nothing)
          case identity >>= either (Left . BungieUnreachable) Right . parseAccountIdentity of
            Left failure -> pure (Left ("授权成功，但读取 Bungie 账号失败：" <> renderBungieFailure failure))
            Right account -> do
              now <- liftIO getCurrentTime
              sealed <- liftIO (sealTokens runtime principal grant)
              upsertLink
                principal
                LinkRow
                  { lrBungieMembershipId = grant.tgMembershipId,
                    lrBungieName = account.aiBungieName,
                    lrMembershipType = (.dmType) <$> account.aiMembership,
                    lrMembershipId = (.dmId) <$> account.aiMembership,
                    lrSealedTokens = sealed,
                    lrAccessExpiresAt = expiresIn now grant.tgAccessExpiresIn,
                    lrRefreshExpiresAt = expiresIn now grant.tgRefreshExpiresIn,
                    lrLinkedAt = now
                  }
              pure (Right (LoginOutcome requester account))

membershipsTarget :: ApiTarget
membershipsTarget = ApiTarget MainHost ["User", "GetMembershipsForCurrentUser"] []

linkedAccount :: (WithConnection :> es, IOE :> es) => PrincipalId -> Eff es (Maybe LinkedAccount)
linkedAccount principal = fmap summary <$> loadLink principal

unlinkAccount :: (WithConnection :> es, IOE :> es) => PrincipalId -> Eff es Bool
unlinkAccount = deleteLink

summary :: LinkRow -> LinkedAccount
summary row =
  LinkedAccount
    { laBungieName = row.lrBungieName,
      laMembership = DestinyMembership <$> row.lrMembershipType <*> row.lrMembershipId,
      laLinkedAt = row.lrLinkedAt,
      laRefreshExpiresAt = row.lrRefreshExpiresAt
    }

-- | The author's current access token. @Right Nothing@ means not linked;
-- @Left@ explains a link that needs attention.
accessTokenFor :: (WithConnection :> es, IOE :> es) => BungieRuntime -> PrincipalId -> Eff es (Either Text (Maybe (Text, LinkedAccount)))
accessTokenFor runtime principal =
  loadLink principal >>= \case
    Nothing -> pure (Right Nothing)
    Just row -> do
      now <- liftIO getCurrentTime
      if addUTCTime 120 now < row.lrAccessExpiresAt
        then pure (fmap (\tokens -> Just (fst tokens, summary row)) (openTokens runtime principal row))
        else fmap (fmap Just) (refreshUnderGate runtime principal (Just row.lrSealedTokens))

-- | Bungie rejected a token that looked valid (revoked, clock skew): refresh
-- once regardless of the stored expiry.
refreshAfterRejection :: (WithConnection :> es, IOE :> es) => BungieRuntime -> PrincipalId -> Text -> Eff es (Either Text (Text, LinkedAccount))
refreshAfterRejection runtime principal rejected =
  loadLink principal >>= \case
    Nothing -> pure (Left notLinked)
    Just row -> case openTokens runtime principal row of
      Right (access, _) | access /= rejected -> pure (Right (access, summary row))
      _ -> refreshUnderGate runtime principal (Just row.lrSealedTokens)

-- Under the gate, a refresh that another caller already completed is reused
-- instead of spending the (rotated) refresh token twice.
refreshUnderGate :: (WithConnection :> es, IOE :> es) => BungieRuntime -> PrincipalId -> Maybe Text -> Eff es (Either Text (Text, LinkedAccount))
refreshUnderGate runtime principal observed =
  withSeqEffToIO $ \run ->
    withMVar runtime.brRefreshGate $ \() -> run $
      loadLink principal >>= \case
        Nothing -> pure (Left notLinked)
        Just row
          | Just row.lrSealedTokens /= observed -> pure (fmap (\(access, _) -> (access, summary row)) (openTokens runtime principal row))
          | otherwise -> case openTokens runtime principal row of
              Left failure -> pure (Left failure)
              Right (_, refresh) -> do
                now <- liftIO getCurrentTime
                if row.lrRefreshExpiresAt <= now
                  then deleteLink principal >> pure (Left expired)
                  else
                    liftIO (refreshAccessToken runtime.brHttp runtime.brConfig refresh) >>= \case
                      Left Nothing -> deleteLink principal >> pure (Left expired)
                      Left (Just transient) -> pure (Left transient)
                      Right grant -> do
                        sealed <- liftIO (sealTokens runtime principal grant)
                        let accessExpires = expiresIn now grant.tgAccessExpiresIn
                            refreshExpires = expiresIn now grant.tgRefreshExpiresIn
                        updateLinkTokens principal sealed accessExpires refreshExpires
                        pure (Right (grant.tgAccessToken, (summary row) {laRefreshExpiresAt = refreshExpires}))
  where
    expired = "Bungie 授权已过期或被撤销，已解除绑定。请私聊我发送 !destiny login 重新登录。"

notLinked :: Text
notLinked = "还没有绑定 Bungie 账号：私聊我发送 !destiny login，在浏览器里登录并批准即可。"

stateHash :: Text -> Text
stateHash = TE.decodeUtf8 . Base16.encode . SHA256.hash . TE.encodeUtf8

expiresIn :: UTCTime -> Int -> UTCTime
expiresIn now seconds = addUTCTime (fromIntegral seconds) now

-- The principal is the associated data: a sealed row copied onto another
-- person fails authentication instead of lending them the account.
sealLabel :: PrincipalId -> Text
sealLabel (PrincipalId principal) = "bungie-link:" <> tshow principal

sealTokens :: BungieRuntime -> PrincipalId -> TokenGrant -> IO Text
sealTokens runtime principal grant =
  sealBrowserState runtime.brVault (sealLabel principal) (object ["access" .= grant.tgAccessToken, "refresh" .= grant.tgRefreshToken])

openTokens :: BungieRuntime -> PrincipalId -> LinkRow -> Either Text (Text, Text)
openTokens runtime principal row = do
  value <- either (const (Left unreadable)) Right (openBrowserState runtime.brVault (sealLabel principal) row.lrSealedTokens)
  either (const (Left unreadable)) Right (parseEither (withObject "tokens" (\o -> (,) <$> o .: "access" <*> o .: "refresh")) value)
  where
    unreadable = "保存的 Bungie 授权无法解密（状态密钥变了？）。请私聊我发送 !destiny login 重新绑定。"
