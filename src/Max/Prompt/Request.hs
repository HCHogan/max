module Max.Prompt.Request (PromptRequest (..)) where

import Data.Int (Int64)
import Data.Set (Set)
import Data.Text (Text)
import Data.Time (TimeZone)
import Max.Context.Types
  ( ContextReadMode,
    ContinuationInput,
    TriggerOrigin,
  )
import Max.Dispatch (DispatchMessage)
import Max.ModelCatalog.Internal (ContextLimits)
import Max.Platform.Types (AdvertisedCaps)
import Max.Session.Types (Session)

data PromptRequest = PromptRequest
  { prContinuation :: !ContinuationInput,
    prLimits :: !ContextLimits,
    prReadMode :: !ContextReadMode,
    prOutputCaps :: !AdvertisedCaps,
    prPersona :: !Text,
    prMultimodal :: !Bool,
    prHistoryTurns :: !Bool,
    prOrigin :: !TriggerOrigin,
    prTimeZone :: !TimeZone,
    prGroupBrief :: ![Text],
    prSkills :: ![(Text, Text)],
    prInFlight :: !(Set Int64),
    prSession :: !Session,
    prTrigger :: !DispatchMessage
  }
