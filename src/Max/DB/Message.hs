-- |
-- == Schema overview (Phase 3)
--
-- Three tables. @messages@ is the heart; everything else attaches to it
-- by message_id. Migrations live under @./migrations/@; sequence numbers
-- are the source of truth for ordering.
--
-- @
--   ┌──────────────────────────── messages ────────────────────────────┐
--   │  message_id              bigint  PK                              │
--   │                          ◄── positive: real QQ message_id        │
--   │                          ◄── negative: synthetic (forward node)  │
--   │  group_id, user_id, self_id    bigint                            │
--   │  received_at             timestamptz default now()               │
--   │  segments                jsonb       (raw OneBot segments)       │
--   │  rendered_text           text        (with [image]/[face] etc.)  │
--   │  rendered_text_tsv       tsvector    GIN-indexed, generated      │
--   │  raw_message             text                                    │
--   │  sender_nickname/card    text                                    │
--   │  reply_to_message_id     bigint      (pointer, not FK)           │
--   │  forwarded_in_message_id bigint  ──► messages.message_id (FK)    │
--   │  forward_position        int                                     │
--   │  is_synthetic            boolean default false                   │
--   │  original_message_id     bigint      (QQ id of forwarded node)   │
--   │  original_sent_at        timestamptz (time the forwarded node    │
--   │                                       was originally posted)     │
--   └──────────────────────────────────────────────────────────────────┘
--                  ▲                                ▲
--                  │ FK on delete cascade           │ self-FK on delete set null
--                  │                                │ (for forwarded children)
--   ┌──── message_images ─────┐         ┌─────── images ──────────────┐
--   │  message_id  bigint  ◄──┘         │  sha256       text  PK      │
--   │  sha256      text   ◄─────────────┤  mime_type    text          │
--   │  seg_index   int                  │  bytes_size   bigint        │
--   │  PK (message_id, seg_index)       │  local_path   text  (rel)   │
--   └─────────────────────────┘         │  width/height int           │
--                                       │  first_seen_at timestamptz  │
--                                       └─────────────────────────────┘
--
--   synthetic_message_id_seq            ──► negated, used as PK for
--                                            forwarded-node rows
--
--   schema_migrations(filename, applied_at)  ── set of applied .sql files
-- @
--
-- Indexes: @(group_id, received_at DESC)@ for chronological group reads;
-- @user_id@, @reply_to_message_id@, @forwarded_in_message_id@,
-- @original_message_id@ for lookups; @GIN(rendered_text_tsv)@ for FTS;
-- @sha256@ on @message_images@ for "which messages reference this blob".
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
