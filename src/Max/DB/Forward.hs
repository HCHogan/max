module Max.DB.Forward
  ( ForwardNodeInsert (..),
    insertForwardNode,
  )
where

import Data.Aeson (Value, toJSON)
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Database.PostgreSQL.Simple (Connection, Only (..), execute, query_, (:.) (..))
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Effectful
import Max.Effects.Db (Db, withConn)
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Types (MessageId (..))

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb v) = toJSONField v

data ForwardNodeInsert = ForwardNodeInsert
  { containerMessageId :: !Int64,
    groupId :: !Int64,
    selfId :: !Int64,
    position :: !Int,
    senderUserId :: !Int64,
    senderNickname :: !Text,
    originalMessageId :: !(Maybe Int64),
    originalSentAt :: !(Maybe Int64),
    segments :: ![Segment]
  }
  deriving stock (Show)

-- | Insert one forwarded node under a synthetic id (negated
-- @synthetic_message_id_seq@). Returns the allocated id so the caller can
-- thread it as a container for nested inline forwards.
insertForwardNode :: Db :> es => ForwardNodeInsert -> Eff es Int64
insertForwardNode n = withConn $ \c -> do
  sid <- allocSyntheticId c
  let segs = Jsonb (toJSON n.segments)
      rendered = renderPlainText n.segments
      replyTo = extractReply n.segments
      sentAt = posixSecondsToUTCTime . fromIntegral <$> n.originalSentAt
      row1 =
        ( sid,
          n.groupId,
          n.senderUserId,
          n.selfId,
          segs,
          rendered,
          "" :: Text,
          n.senderNickname,
          Nothing :: Maybe Text,
          replyTo
        )
      row2 =
        ( n.containerMessageId,
          n.position,
          n.originalMessageId,
          sentAt
        )
  _ <-
    execute
      c
      "INSERT INTO messages \
      \ (message_id, group_id, user_id, self_id, segments, rendered_text, raw_message, \
      \  sender_nickname, sender_card, reply_to_message_id, \
      \  forwarded_in_message_id, forward_position, original_message_id, original_sent_at, \
      \  is_synthetic) \
      \ VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,true) \
      \ ON CONFLICT (message_id) DO NOTHING"
      (row1 :. row2)
  pure sid

allocSyntheticId :: Connection -> IO Int64
allocSyntheticId c = do
  rows <- query_ c "SELECT -nextval('synthetic_message_id_seq')"
  case rows of
    [Only n] -> pure n
    _ -> error "allocSyntheticId: sequence query returned no rows"

extractReply :: [Segment] -> Maybe Int64
extractReply segs = listToMaybe [m | SegReply (MessageId m) <- segs]
