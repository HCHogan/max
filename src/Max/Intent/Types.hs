-- | Configuration shared by the proactive-intent worker and immutable
-- dispatch snapshots.  Kept separate from "Max.Intent" so the runtime
-- configuration store does not depend on the worker implementation.
module Max.Intent.Types
  ( IntentConfig (..),
  )
where

import Data.Text (Text)

-- | Resolved @intent.*@ config; presence enables the whole feature.
data IntentConfig = IntentConfig
  { -- | LLM profile the classifier calls (fast + cheap, e.g. a flash
    -- tier model).
    icProfile :: !Text,
    -- | Seconds after a proactive reply during which topic verdicts are
    -- suppressed (name-calls and conversation follow-ups are exempt).
    icCooldownSeconds :: !Int,
    -- | Hard cap on proactive replies per group per hour, all kinds.
    icMaxPerHour :: !Int,
    -- | How many recent group messages the classifier sees.
    icContextLines :: !Int
  }
  deriving stock (Show, Eq)
