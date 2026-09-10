module PromptFixture (promptRequest) where

import Data.Set qualified as Set
import Data.Time (utc)
import Max.Context.Types (noContinuation)
import Max.Dispatch (DispatchMessage)
import Max.ModelCatalog (defaultContextLimits)
import Max.Platform.Types (qqAdvertisedCaps)
import Max.Prompt (ContextReadMode (..), PromptRequest (..), TriggerOrigin (..))
import Max.Session.Types (Session)

promptRequest :: Session -> DispatchMessage -> PromptRequest
promptRequest session trigger =
  PromptRequest
    { prContinuation = noContinuation,
      prLimits = defaultContextLimits,
      prReadMode = TieredContext,
      prOutputCaps = qqAdvertisedCaps,
      prPersona = "default-persona",
      prMultimodal = False,
      prHistoryTurns = False,
      prOrigin = OriginDirect,
      prTimeZone = utc,
      prGroupBrief = [],
      prSkills = [],
      prInFlight = Set.empty,
      prSession = session,
      prTrigger = trigger
    }
