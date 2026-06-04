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

-- | One branch of one group's session.  See "Max.Session" for the
-- mutator surface; this module just defines the record so the storage
-- module doesn't have to depend on the STM-backed registry.
data Session = Session
  { groupId :: !GroupId,
    branch :: !Text,
    -- | LLM profile name from @[llm.profiles.*]@.  Always resolved
    -- (never empty) — defaults from the registry are applied on load.
    model :: !Text,
    -- | Persona override.  'Nothing' means inherit @AppConfig.persona@.
    persona :: !(Maybe Text),
    -- | Queued !btw notes consumed by the next dispatch (Phase 6a) or
    -- injected into a running agent task (Phase 6b).
    btwNotes :: ![Text],
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
    thinkingOverride :: !(Maybe Bool)
  }
  deriving stock (Show)
