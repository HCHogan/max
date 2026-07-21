-- |
-- 'Session' data type only.  Lives in its own module so that
-- "Max.DB.Session" (storage) and "Max.Session" (in-memory registry +
-- helpers) can both import it without a cycle.
module Max.Session.Types
  ( Session (..),
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import OneBot.Types (GroupId)

-- | One group's session.  See "Max.Session" for the mutator surface;
-- this module just defines the record so the storage module doesn't
-- have to depend on the STM-backed registry.
data Session = Session
  { groupId :: !GroupId,
    -- | LLM profile name from @[llm.profiles.*]@.  Always resolved
    -- (never empty) — defaults from the registry are applied on load.
    model :: !Text,
    -- | Persona override.  'Nothing' means inherit @AppConfig.persona@.
    persona :: !(Maybe Text),
    -- | Watermark set by @!clear@.  When 'Just', ambient group context
    -- AND reconstructed mention history older than this are excluded
    -- from the prompt.  'Nothing' means no filtering.  Pinned messages
    -- (see 'pinned') bypass this entirely.  Survives across restarts.
    clearedAt :: !(Maybe UTCTime),
    -- | Explicit message_ids the user pinned via @!pin@.  These get
    -- included in every prompt regardless of 'clearedAt'.  Order
    -- preserved (display reflects user's pin order).
    pinned :: ![Int64],
    -- | Per-session thinking-mode override, set by @!model think
    -- on@/@off@.  'Nothing' means follow the profile's (or server's)
    -- default; 'Just' overrides for this session.
    thinkingOverride :: !(Maybe Bool),
    -- | Per-session debug override, set by @!debug on@/@off@.
    -- 'Nothing' means follow @AppConfig.debug@.  When effective
    -- debug is on, tool calls are announced in the group.
    debugOverride :: !(Maybe Bool),
    -- | Per-session sticker override, set by @!sticker on@/@off@.
    -- 'Nothing' means follow @AppConfig.stickersEnabled@.  When
    -- effective sticker sending is on, the @send_sticker@ tool is
    -- registered so the model may post stickers.
    stickerOverride :: !(Maybe Bool),
    -- | Per-session proactive-trigger override, set by @!proactive
    -- on@/@off@.  'Nothing' means follow the config default (on
    -- whenever @intent.profile@ is configured).  When effective
    -- proactive mode is on, the intent classifier may trigger the bot
    -- on messages that neither @-mention nor quote it.
    proactiveOverride :: !(Maybe Bool)
  }
  deriving stock (Show)
