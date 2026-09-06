{-# LANGUAGE OverloadedStrings #-}

-- |
-- What the proxy in front of the subscription knows about it.
--
-- max reaches the GPT-5.x models through CLIProxyAPI, which holds the
-- ChatGPT OAuth credentials and rotates a pool of them.  That puts the
-- only copy of "is the subscription still serving" on the far side of
-- a socket: max sees a 503 and a retry storm, the proxy sees which
-- account burned out and when it comes back.  This is a read-only
-- client for the proxy's management API, so that question has an
-- answer that doesn't require an ssh session.
--
-- What this deliberately does not claim to know is how much of the
-- ChatGPT 5-hour and weekly windows is left.  Codex reports that on
-- every response, but CLIProxyAPI neither reads those headers nor
-- forwards them downstream — it learns a credential is spent by being
-- told @usage_limit_reached@, after the fact.  So 'crUnavailable' plus
-- 'crNextRetryAfter' is the honest reading of what comes back: a
-- warning light, not a fuel gauge.
module Max.CliProxy
  ( CliProxyConfig (..),
    Credential (..),
    Bucket (..),
    fetchCredentials,
    credentialJson,

    -- * Exposed for tests
    parseCredentials,
    managementUrl,
    serving,
  )
where

-- object/(.=) ride in on the Effectful.Log re-export.
import Data.Aeson (FromJSON (..), Value (..), withObject, (.!=), (.:?))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Max.Effects.Http (DownloadError (..), Http, getBytesWith, renderDownloadError)
import Max.HttpRuntime (TransportFailure (..))

-- | Resolved @cliproxy.*@ config; presence of the management key
-- enables the section, the same shape every other optional feature
-- uses.
data CliProxyConfig = CliProxyConfig
  { -- | The proxy's root.  A @\/v1@ tail is tolerated so this can be
    -- copy-pasted from an @llm.profiles.*.base_url@, which is where
    -- everyone will reach for it first.
    cpBaseUrl :: !Text,
    -- | Sent as @Authorization: Bearer ...@.  CLIProxyAPI requires it
    -- on every management call, loopback included.
    cpManagementKey :: !Text
  }
  deriving stock (Show, Eq)

-- | One 10-minute slice of a credential's recent traffic.  The proxy
-- keeps twenty of them, labelled in its own local time.
data Bucket = Bucket
  { bkTime :: !Text,
    bkSuccess :: !Int64,
    bkFailed :: !Int64
  }
  deriving stock (Show, Eq)

instance FromJSON Bucket where
  parseJSON = withObject "recent-request bucket" $ \o ->
    Bucket
      <$> o .:? "time" .!= ""
      <*> o .:? "success" .!= 0
      <*> o .:? "failed" .!= 0

-- | One credential in the proxy's pool.
--
-- Everything is optional-with-a-default on purpose: this is another
-- project's JSON on the other end of an upgrade we don't control, and
-- a renamed field should cost one blank column in the panel, not a
-- 500 on the whole endpoint.
data Credential = Credential
  { crId :: !Text,
    -- | @codex@, @gemini@, @claude@ … — which upstream this speaks.
    crProvider :: !Text,
    crLabel :: !(Maybe Text),
    crEmail :: !(Maybe Text),
    -- | @active@ \/ @error@ \/ @disabled@ \/ @refreshing@ \/ @pending@.
    crStatus :: !Text,
    crStatusMessage :: !(Maybe Text),
    crDisabled :: !Bool,
    -- | Transient unavailability — in practice, quota exhausted.
    crUnavailable :: !Bool,
    -- | When a burnt credential is due back.  Absent while healthy.
    crNextRetryAfter :: !(Maybe UTCTime),
    crSuccess :: !Int64,
    crFailed :: !Int64,
    crRecent :: ![Bucket],
    -- | ChatGPT plan tier, decoded by the proxy from the OAuth id
    -- token.  @codex@ credentials only.
    crPlanType :: !(Maybe Text),
    -- | Subscription expiry as the id token states it; the claim is
    -- untyped upstream, so it rides through as-is rather than being
    -- guessed into a 'UTCTime'.
    crSubscriptionUntil :: !(Maybe Value)
  }
  deriving stock (Show, Eq)

instance FromJSON Credential where
  parseJSON = withObject "auth file" $ \o -> do
    claims <- o .:? "id_token" .!= KM.empty
    Credential
      <$> o .:? "id" .!= ""
      <*> o .:? "provider" .!= ""
      <*> (nonBlank <$> o .:? "label")
      <*> (nonBlank <$> o .:? "email")
      <*> o .:? "status" .!= "unknown"
      <*> (nonBlank <$> o .:? "status_message")
      <*> o .:? "disabled" .!= False
      <*> o .:? "unavailable" .!= False
      <*> o .:? "next_retry_after"
      <*> o .:? "success" .!= 0
      <*> o .:? "failed" .!= 0
      <*> o .:? "recent_requests" .!= []
      <*> pure (KM.lookup "plan_type" claims >>= asText)
      <*> pure (KM.lookup "chatgpt_subscription_active_until" claims)
    where
      nonBlank (Just t) | not (T.null (T.strip t)) = Just t
      nonBlank _ = Nothing
      asText (String t) | not (T.null t) = Just t
      asText _ = Nothing

-- | Can this credential take a request right now?  The proxy spreads
-- the answer over four fields; a caller wanting to know whether the
-- subscription is up shouldn't have to reassemble it.
serving :: Credential -> Bool
serving c =
  not c.crDisabled
    && not c.crUnavailable
    && c.crStatus `notElem` ["disabled", "error"]

-- | Where a management endpoint lives, given the configured root.
--
-- Tolerating the @\/v1@ tail is the whole reason this isn't inline:
-- the management API hangs off the server root, but the URL a user has
-- at hand ends in @\/v1@, and the failure that mismatch produces is a
-- 404 that reads exactly like "remote management is off".
managementUrl :: CliProxyConfig -> Text -> Text
managementUrl cfg path = root <> "/v0/management" <> path
  where
    trimmed = T.dropWhileEnd (== '/') cfg.cpBaseUrl
    root = fromMaybe trimmed (T.stripSuffix "/v1" trimmed)

-- | The pool, as the proxy currently sees it.
fetchCredentials ::
  (Http :> es, Log :> es) =>
  CliProxyConfig ->
  Eff es (Either Text [Credential])
fetchCredentials cfg = do
  res <-
    getBytesWith
      (managementUrl cfg "/auth-files")
      [("Authorization", "Bearer " <> cfg.cpManagementKey)]
      responseLimit
  case res of
    Left err -> failWith (explain err)
    Right (bytes, _) -> case parseCredentials (LBS.fromStrict bytes) of
      Left err -> failWith err
      Right creds -> pure (Right creds)
  where
    failWith msg = do
      logAttention "cliproxy: management query failed" $ object ["error" .= msg]
      pure (Left msg)

-- | Decode an @\/auth-files@ body.
parseCredentials :: LBS.ByteString -> Either Text [Credential]
parseCredentials raw = case A.eitherDecode raw of
  Left e -> Left ("unreadable management response: " <> T.pack e)
  Right (Files cs) -> Right cs

newtype Files = Files [Credential]

instance FromJSON Files where
  parseJSON = withObject "auth-files response" $ \o -> Files <$> o .:? "files" .!= []

-- | A pool listing is a few KB; anything near this is a wrong URL
-- answering, and reading it all would be the mistake.
responseLimit :: Int
responseLimit = 1024 * 1024

-- | Say what the status code means here.  A bare @HTTP 404@ from this
-- endpoint has exactly one likely cause and it isn't a typo'd path.
explain :: DownloadError -> Text
explain failure =
  renderDownloadError failure <> case failure of
    DownloadTransport (HttpStatusFailure 404 _ _ _) -> " — the proxy has no management API; set remote-management.secret-key in its config"
    DownloadTransport (HttpStatusFailure 401 _ _ _) -> " — management key rejected"
    _ -> ""

-- | One credential, rendered for the admin API.
--
-- The two derived fields are the point of the endpoint: @serving@
-- collapses the four-way status into the answer callers actually want,
-- and @recent@ totals the buckets so a health check doesn't have to
-- sum an array to learn whether anything has gone through lately.
credentialJson :: Credential -> Value
credentialJson c =
  object
    [ "id" .= c.crId,
      "provider" .= c.crProvider,
      "label" .= c.crLabel,
      "email" .= c.crEmail,
      "plan_type" .= c.crPlanType,
      "subscription_until" .= c.crSubscriptionUntil,
      "status" .= c.crStatus,
      "status_message" .= c.crStatusMessage,
      "disabled" .= c.crDisabled,
      "unavailable" .= c.crUnavailable,
      "next_retry_after" .= c.crNextRetryAfter,
      "serving" .= serving c,
      "success" .= c.crSuccess,
      "failed" .= c.crFailed,
      "recent"
        .= object
          [ "window_minutes" .= (length c.crRecent * 10),
            "success" .= sum (map (.bkSuccess) c.crRecent),
            "failed" .= sum (map (.bkFailed) c.crRecent),
            "buckets"
              .= [ object
                     [ "time" .= b.bkTime,
                       "success" .= b.bkSuccess,
                       "failed" .= b.bkFailed
                     ]
                 | b <- c.crRecent
                 ]
          ]
    ]
