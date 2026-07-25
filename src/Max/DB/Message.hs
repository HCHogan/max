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
    insertOutbound,
    insertSilence,
  )
where

import Data.Aeson (Value, toJSON)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute)
import OneBot.Event (GroupMessage (..), Sender (..))
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb v) = toJSONField v

-- | Insert a group message; idempotent on @message_id@ (NapCat may replay
-- the same event after our reverse-WS reconnects).
-- | @isCommand@ marks a @!@-command: the caller decides, because the
-- authority on what parses as a command is "Max.Command.Parser" and a
-- DB module has no business importing it.  Command rows stay out of
-- the transcript ("Max.DB.History") — they are UI, not conversation.
insertGroupMessage :: (WithConnection :> es, IOE :> es) => Bool -> GroupMessage -> Eff es ()
insertGroupMessage isCommand gm = do
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
      "INSERT INTO messages \
      \ (message_id, group_id, user_id, self_id, \
      \  segments, rendered_text, raw_message, \
      \  sender_nickname, sender_card, reply_to_message_id, is_command) \
      \ VALUES (?,?,?,?,?,?,?,?,?,?,?) \
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
        replyTo,
        isCommand
      )
  pure ()

extractReply :: [Segment] -> Maybe Int64
extractReply segs =
  listToMaybe [m | SegReply (MessageId m) <- segs]

-- | Persist a bot silence ('[silence]' / '[silence:表情名]') as a
-- synthetic bot row.  Nothing goes out to QQ — this exists purely so
-- the next dispatch's mention history shows the turn was already
-- declined; without it the unanswered question reads as pending and
-- the model answers it a dispatch late.  @reply_to_message_id@ points
-- at the declined trigger, which both anchors the silence next to its
-- question and (via the bot-quoted clause in 'fetchMentionHistory')
-- pulls a declined *proactive* trigger into mention history at all.
insertSilence ::
  (WithConnection :> es, IOE :> es) =>
  GroupMessage -> -- the declined trigger
  Text -> -- the silence reply text, e.g. "[silence:吃瓜]"
  Eff es ()
insertSilence gm rendered = do
  let GroupId gid = gm.groupId
      UserId selfId = gm.selfId
      MessageId mid = gm.messageId
      -- A poke's synthesized trigger has no real message id.
      replyTo = if mid == 0 then Nothing else Just mid
  _ <-
    execute
      "INSERT INTO messages \
      \ (message_id, group_id, user_id, self_id, \
      \  segments, rendered_text, raw_message, \
      \  is_synthetic, reply_to_message_id) \
      \ VALUES (-nextval('synthetic_message_id_seq'),?,?,?,?,?,'',true,?)"
      (gid, selfId, selfId, Jsonb (toJSON ([] :: [Segment])), rendered, replyTo)
  pure ()

-- | Insert an *outbound* message (something the bot itself sent) into
-- the messages table.  Used by the LLM-reply path so mention history
-- can be reconstructed from a single source of truth at dispatch time.
-- NapCat occasionally sends our own message back as an event too;
-- whichever insert runs first claims the row, so on conflict we
-- overwrite @rendered_text@ — ours is the normalised form (table
-- markdown source, @[sticker#\<id\>: …]@), which must win over the
-- echo's plain 'renderPlainText' regardless of arrival order.  The
-- echo's own insert is DO NOTHING, so the reverse order needs no care.
--
-- @renderedOverride@ replaces the default 'renderPlainText' of the
-- sent segments: a table sent as an image should read back as its
-- markdown source in the bot's own history, not as @[image]@.
insertOutbound ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  UserId -> -- bot's self_id; both user_id and self_id columns get this
  Text -> -- nickname for the sender column (e.g. "max")
  MessageId ->
  Maybe Text -> -- renderedOverride
  [Segment] ->
  Eff es ()
insertOutbound (GroupId gid) (UserId sid) nick (MessageId mid) renderedOverride segs = do
  let segsJson = Jsonb (toJSON segs)
      rendered = fromMaybe (renderPlainText segs) renderedOverride
      replyTo = extractReply segs
  _ <-
    execute
      "INSERT INTO messages \
      \ (message_id, group_id, user_id, self_id, \
      \  segments, rendered_text, raw_message, \
      \  sender_nickname, sender_card, reply_to_message_id) \
      \ VALUES (?,?,?,?,?,?,?,?,?,?) \
      \ ON CONFLICT (message_id) DO UPDATE \
      \   SET rendered_text = EXCLUDED.rendered_text"
      ( mid,
        gid,
        sid, -- user_id = bot's id (bot is the sender)
        sid, -- self_id same
        segsJson,
        rendered,
        "" :: Text,
        Just nick,
        Nothing :: Maybe Text,
        replyTo
      )
  pure ()
