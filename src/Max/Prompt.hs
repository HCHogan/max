module Max.Prompt
  ( -- * Pipeline
    PromptRequest (..),
    buildContext,
    ContextReadMode (..),
    TriggerOrigin (..),

    -- * Building blocks (exposed for tests)
    PromptInputs (..),
    ContextCandidates (..),
    SelectedContext (..),
    PromptImage (..),
    ContextCompartment (..),
    CompartmentTier (..),
    ContextSnapshot (..),
    csInputs,
    ContextPlan (..),
    cpInputs,
    collectContextPreview,
    planContext,
    materializeTieredHistory,
    HistoryTokenWatermarks (..),
    applyBaseCompartmentTiers,
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

import Control.Monad (unless)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Effectful
import Effectful.Log (Log, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Max.Context (ContextBudget (..))
import Max.Context.Media (tagMediaMarkers)
import Max.Context.Policy (applyBaseCompartmentTiers)
import Max.Context.Types
  ( CompartmentTier (..),
    ContextCandidates (..),
    ContextCompartment (..),
    ContextPlan (..),
    ContextReadMode (..),
    ContextSnapshot (..),
    HistoryTokenWatermarks (..),
    PromptImage (..),
    PromptInputs (..),
    SelectedContext (..),
    TriggerOrigin (..),
    cpInputs,
    csInputs,
  )
import Max.ContextTraceStore (recordContextPlanTrace)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.History.Media (withMediaHandles)
import Max.Dispatch (DispatchMessage (canonicalId, groupId))
import Max.Effects.Blob (Blob)
import Max.Effects.ContextQuery (collectContextPreview)
import Max.LLM.Types (ChatMessage)
import Max.Platform.Types (CanonicalMessageId (..))
import Max.Prompt.Collect (collectContextSnapshot)
import Max.Prompt.Materialize
  ( collectPublishedHistory,
    materializeTieredHistory,
  )
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
import Max.Util (trySync)
import OneBot.Types (GroupId (..))

buildContext ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  PromptRequest -> Eff es ([ChatMessage], [(Int64, Text)])
buildContext request = do
  let limits = request.prLimits
      readMode = request.prReadMode
      gm = request.prTrigger
  now <- liftIO getCurrentTime
  history <- collectPublishedHistory now request
  snapshot <- collectContextSnapshot request now history
  let plan = planContext limits snapshot
      CanonicalMessageId triggerMessageId = gm.canonicalId
      scope = conversationScopeFor gm.groupId
  traceStored <-
    trySync $
      recordContextPlanTrace
        scope
        triggerMessageId
        (contextReadModeText readMode)
        plan.cpPolicyVersion
        plan.cpMaterializationVersion
        plan.cpMaterializationReason
        plan.cpBudget
        plan.cpEstimatedPromptTokens
        plan.cpWithinBudget
        plan.cpTrace
  case traceStored of
    Left err ->
      logAttention "context: failed to persist planning trace" $
        object ["group_id" .= (let GroupId groupId = gm.groupId in groupId), "error" .= T.pack (show err)]
    Right () -> pure ()
  unless plan.cpWithinBudget $
    logAttention "context plan exceeds model input budget" $
      object
        [ "estimated_prompt_tokens" .= plan.cpEstimatedPromptTokens,
          "prompt_token_limit" .= plan.cpBudget.cbPromptTokenLimit,
          "policy_version" .= plan.cpPolicyVersion
        ]
  pure (renderContextPlan plan, contextRoster (cpInputs plan))

contextReadModeText :: ContextReadMode -> Text
contextReadModeText = \case
  TieredContext -> "tiered"
  RawLedgerEmergency -> "raw_emergency"
