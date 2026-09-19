module Max.Prompt
  ( -- * Pipeline
    PromptRequest (..),
    buildContext,
    ContextReadMode (..),
    TriggerOrigin (..),

    -- * Building blocks (exposed for tests)
    PromptInputs (..),
    SelectedContext (..),
    PromptImage (..),
    ContextCompartment (..),
    ContextSnapshot (..),
    ContextPlan (..),
    cpInputs,
    planContext,
    renderContextPlan,
    renderContext,
    contextRoster,
    applyStickerCaptions,
    tagImageMarkers,

    -- * Shared line rendering (used by "Max.Intent" / "Max.Handler")
    renderHistoryLine,
    renderCurrentLine,

    -- * Forward markers (shared with "Max.Tools")
    tagMediaMarkers,
    withMediaHandles,
  )
where

import Control.Monad (unless, when)
import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Text (Text)
import Effectful
import Effectful.Log (Log, logAttention, logTrace, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Max.Context (ContextBudget (..), ContextTrace (..))
import Max.Context.Media (tagMediaMarkers)
import Max.Context.Types
  ( ContextCompartment (..),
    ContextPlan (..),
    ContextReadMode (..),
    ContextSnapshot (..),
    PromptImage (..),
    PromptInputs (..),
    SelectedContext (..),
    TriggerOrigin (..),
    cpInputs,
  )
import Max.DB.History.Media (withMediaHandles)
import Max.Dispatch (DispatchMessage (canonicalId, groupId))
import Max.Effects.Blob (Blob)
import Max.LLM.Types (ChatMessage)
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Prompt.Collect qualified as Collect
import Max.Prompt.Render
  ( applyStickerCaptions,
    contextRoster,
    planContext,
    renderContext,
    renderContextPlan,
    renderCurrentLine,
    renderHistoryLine,
    tagImageMarkers,
  )
import Max.Prompt.Request (PromptRequest (..))
import OneBot.Types (GroupId (..))

buildContext ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  PromptRequest -> Eff es ([ChatMessage], [(Int64, Text)])
buildContext request = do
  snapshot <- Collect.collectContextPreview request
  let plan = planContext request.prLimits snapshot
      CanonicalMessageId triggerMessageId = request.prTrigger.canonicalId
      GroupId groupId = request.prTrigger.groupId
  -- Sample body-free decisions only when trace logging is enabled.
  when (triggerMessageId `mod` 16 == 0) $
    logTrace "context: sampled prompt plan" $
      object
        [ "group_id" .= groupId,
          "trigger_message_id" .= triggerMessageId,
          "policy_version" .= plan.cpPolicyVersion,
          "estimated_prompt_tokens" .= plan.cpEstimatedPromptTokens,
          "prompt_token_limit" .= plan.cpBudget.cbPromptTokenLimit,
          "within_budget" .= plan.cpWithinBudget,
          "decisions" .= map traceJson plan.cpTrace
        ]
  unless plan.cpWithinBudget $
    logAttention "context plan exceeds model input budget" $
      object
        [ "estimated_prompt_tokens" .= plan.cpEstimatedPromptTokens,
          "prompt_token_limit" .= plan.cpBudget.cbPromptTokenLimit,
          "policy_version" .= plan.cpPolicyVersion
        ]
  pure (renderContextPlan plan, contextRoster (cpInputs plan))

traceJson :: ContextTrace -> Value
traceJson trace =
  object
    [ "source" .= trace.ctSource,
      "estimated_tokens" .= trace.ctEstimatedTokens,
      "decision" .= show trace.ctDecision,
      "reason" .= trace.ctReason
    ]
