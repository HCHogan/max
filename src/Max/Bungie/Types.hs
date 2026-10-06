-- | Bungie.net configuration and the wire shapes of its OAuth and membership
-- responses. Pure: no HTTP, storage or secrets handling beyond redaction.
module Max.Bungie.Types
  ( BungieConfig (..),
    TokenGrant (..),
    DestinyMembership (..),
    AccountIdentity (..),
    parseTokenGrant,
    parseAccountIdentity,
    bungieDisplayName,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Int (Int64)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Text.Read (readMaybe)

-- | One Confidential application registered by the operator at
-- bungie.net/en/Application. Players never see these values.
data BungieConfig = BungieConfig
  { bcApiKey :: !Text,
    bcClientId :: !Text,
    bcClientSecret :: !Text
  }
  deriving stock (Eq)

instance Show BungieConfig where
  show config = "BungieConfig {bcClientId = " <> show config.bcClientId <> ", <api key and secret redacted>}"

-- | A successful authorization-code or refresh-token exchange.
data TokenGrant = TokenGrant
  { tgAccessToken :: !Text,
    tgAccessExpiresIn :: !Int,
    tgRefreshToken :: !Text,
    tgRefreshExpiresIn :: !Int,
    tgMembershipId :: !Int64
  }
  deriving stock (Eq)

instance Show TokenGrant where
  show grant = "TokenGrant {tgMembershipId = " <> show grant.tgMembershipId <> ", <tokens redacted>}"

data DestinyMembership = DestinyMembership
  { dmType :: !Int,
    dmId :: !Int64
  }
  deriving stock (Show, Eq)

-- | Who logged in: the Bungie.net account and the Destiny membership that
-- represents it (the cross-save primary when there is one).
data AccountIdentity = AccountIdentity
  { aiBungieName :: !Text,
    aiMembership :: !(Maybe DestinyMembership)
  }
  deriving stock (Show, Eq)

-- | Confidential clients always receive a refresh token; a response without
-- one means the application was registered as Public, which cannot stay
-- linked for longer than an hour.
parseTokenGrant :: Value -> Either Text TokenGrant
parseTokenGrant = either (Left . T.pack) Right . parseEither grant
  where
    grant = withObject "token response" $ \o -> do
      access <- o .: "access_token"
      expires <- o .: "expires_in"
      refresh <-
        o .:? "refresh_token" >>= \case
          Just token -> pure token
          Nothing -> fail "no refresh_token: register the Bungie application as Confidential"
      refreshExpires <- o .:? "refresh_expires_in" .!= 7776000
      membership <- o .: "membership_id" >>= int64Text
      pure (TokenGrant access expires refresh refreshExpires membership)

-- | Decode @User/GetMembershipsForCurrentUser@'s Response.
parseAccountIdentity :: Value -> Either Text AccountIdentity
parseAccountIdentity = either (Left . T.pack) Right . parseEither identity
  where
    identity = withObject "memberships" $ \o -> do
      user <- o .: "bungieNetUser"
      name <- userName user
      memberships <- o .:? "destinyMemberships" .!= []
      decoded <- traverse membership memberships
      primary <- traverse int64Text =<< o .:? "primaryMembershipId"
      let chosen = case primary of
            Just wanted | Just (m, _) <- find ((== wanted) . (.dmId) . fst) decoded -> Just m
            _ -> fst <$> (find snd decoded <|> headMaybe decoded)
      pure (AccountIdentity name chosen)
    -- A membership that cross save does not override is the one Destiny uses.
    membership = withObject "membership" $ \m -> do
      kind <- m .: "membershipType"
      ident <- m .: "membershipId" >>= int64Text
      override <- m .:? "crossSaveOverride" .!= 0
      pure (DestinyMembership kind ident, override == 0 || override == kind)
    userName = withObject "bungieNetUser" $ \u -> do
      global <- u .:? "cachedBungieGlobalDisplayName"
      code <- u .:? "cachedBungieGlobalDisplayNameCode"
      unique <- u .:? "uniqueName"
      display <- u .:? "displayName"
      pure $ case global of
        Just g | not (T.null g) -> bungieDisplayName g code
        _ -> fromMaybe "Guardian" (unique <|> display)
    headMaybe = \case
      x : _ -> Just x
      [] -> Nothing

-- | Bungie Names render as @Name#0123@: the code is always four digits.
bungieDisplayName :: Text -> Maybe Int -> Text
bungieDisplayName name = \case
  Just code -> name <> "#" <> T.justifyRight 4 '0' (T.pack (show code))
  Nothing -> name

-- Bungie serializes 64-bit ids as strings; accept numbers too.
int64Text :: Value -> Parser Int64
int64Text = \case
  String text | Just n <- readMaybe (T.unpack text) -> pure n
  Number n -> parseJSON (Number n)
  _ -> fail "expected a 64-bit id"
