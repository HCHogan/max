module OneBot.Types
  ( UserId (..),
    GroupId (..),
    MessageId (..),
    parseIntId,
    -- * Private chats as pseudo-groups
    privateChatGroupId,
    privateChatUserId,
    isPrivateChat,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, typeMismatch)
import Data.Int (Int64)
import Data.Scientific (floatingOrInteger)
import Data.Text.Read qualified as TR

-- | Parse an integer ID that may be encoded as either a JSON number or a JSON
-- string. OneBot 11 implementations (NapCat included) are inconsistent: e.g.
-- @user_id@ is a number while @at.data.qq@ is a string.
parseIntId :: String -> Value -> Parser Int64
parseIntId name = \case
  Number n -> case floatingOrInteger n of
    Right (i :: Integer) ->
      if i >= fromIntegral (minBound :: Int64) && i <= fromIntegral (maxBound :: Int64)
        then pure (fromIntegral i)
        else fail (name <> ": out of Int64 range")
    Left (_ :: Double) -> fail (name <> ": expected integer, got float")
  String s -> case TR.signed TR.decimal s of
    Right (i, "") -> pure i
    _ -> fail (name <> ": string is not a decimal integer")
  v -> typeMismatch name v

newtype UserId = UserId Int64
  deriving newtype (Eq, Ord, Show, ToJSON)

instance FromJSON UserId where
  parseJSON = fmap UserId . parseIntId "UserId"

newtype GroupId = GroupId Int64
  deriving newtype (Eq, Ord, Show, ToJSON)

instance FromJSON GroupId where
  parseJSON = fmap GroupId . parseIntId "GroupId"

newtype MessageId = MessageId Int64
  deriving newtype (Eq, Ord, Show, ToJSON)

instance FromJSON MessageId where
  parseJSON = fmap MessageId . parseIntId "MessageId"

--------------------------------------------------------------------------------
-- Private chats and foreign compatibility groups.
--
-- The whole pipeline (sessions, history, memories, sandboxes,
-- commands) is keyed by 'GroupId'.  Rather than thread a second
-- conversation kind through all of it, a private chat with user @u@ is
-- identified by the pseudo group id @-u@. Foreign platforms later reserved
-- ids at and below -10^12 for their own users, messages, and group channels.
-- The numeric range therefore carries the legacy chat kind: QQ DMs are in
-- @(-10^12, 0)@; foreign synthetic groups are @<= -10^12@.

privateChatGroupId :: UserId -> GroupId
privateChatGroupId (UserId u) = GroupId (negate u)

-- | Recover the peer from a pseudo group id.  Only meaningful when
-- 'isPrivateChat' holds.
privateChatUserId :: GroupId -> UserId
privateChatUserId (GroupId g) = UserId (negate g)

isPrivateChat :: GroupId -> Bool
isPrivateChat (GroupId g) = g < 0 && g > negate foreignCompatibilityBase

foreignCompatibilityBase :: Int64
foreignCompatibilityBase = 1000000000000
