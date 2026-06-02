-- |
-- 'Session' data type only.  Lives in its own module so that
-- "Max.DB.Session" (storage) and "Max.Session" (in-memory registry +
-- helpers) can both import it without a cycle.
module Max.Session.Types
  ( Session (..),
  )
where

import Data.Text (Text)
import Max.Effects.LLM (ChatMessage)
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
    -- | The bot's @-mention conversation history, OpenAI shape.
    history :: ![ChatMessage],
    -- | Queued !btw notes consumed by the next dispatch (Phase 6a) or
    -- injected into a running agent task (Phase 6b).
    btwNotes :: ![Text]
  }
  deriving stock (Show)
