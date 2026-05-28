module Max.DB.Message
  ( insertGroupMessage,
  )
where

import Data.Aeson (Value, toJSON)
import Data.Int (Int64)
import Data.Maybe (listToMaybe)
import Database.PostgreSQL.Simple (execute)
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Max.DB.Connection (DbPool, withConn)
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

-- | Wrap a JSON 'Value' so it inserts into a @jsonb@ column.
newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb v) = toJSONField v

-- | Insert a group message. Idempotent on @message_id@: NapCat may replay
-- the same event after our reverse-WS reconnects.
insertGroupMessage :: DbPool -> GroupMessage -> IO ()
insertGroupMessage pool gm = withConn pool $ \c -> do
  let MessageId mid = gm.messageId
      GroupId gid = gm.groupId
      UserId uid = gm.userId
      UserId sid = gm.selfId
      Sender _ nick card = gm.sender
      segs = Jsonb (toJSON gm.message)
      rendered = renderPlainText gm.message
      replyTo = extractReply gm.message
  _ <-
    execute
      c
      "INSERT INTO messages \
      \ (message_id, group_id, user_id, self_id, \
      \  segments, rendered_text, raw_message, \
      \  sender_nickname, sender_card, reply_to_message_id) \
      \ VALUES (?,?,?,?,?,?,?,?,?,?) \
      \ ON CONFLICT (message_id) DO NOTHING"
      ( mid,
        gid,
        uid,
        sid,
        segs,
        rendered,
        gm.rawMessage,
        nick,
        card,
        replyTo
      )
  pure ()

extractReply :: [Segment] -> Maybe Int64
extractReply segs =
  listToMaybe [m | SegReply (MessageId m) <- segs]
