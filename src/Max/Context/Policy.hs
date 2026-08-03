-- |
-- Pure deterministic selection over a collected context snapshot.  The
-- renderer supplies block-local cost functions once; the policy never invokes
-- the complete prompt renderer while degrading candidates.
module Max.Context.Policy
  ( ContextCostModel (..),
    PolicyDrop (..),
    selectContextTo,
    applyBaseCompartmentTiers,
    selectedCompartmentSummary,
    compartmentTierText,
  )
where

import Data.Function (on)
import Data.List (minimumBy)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime)
import Max.Context (estimateTextTokens)
import Max.Context.Types
import Max.DB.History (HistoryItem (..))
import Max.MemoryStore (MemoryId, MemoryItem (..))

data ContextCostModel = ContextCostModel
  { ccmMemoryBlockTokens :: PromptInputs -> Int,
    ccmCompartmentBlockTokens :: PromptInputs -> Int
  }

data PolicyDrop = PolicyDrop
  { pdSource :: !Text,
    pdTokens :: !Int
  }

selectContextTo :: ContextCostModel -> Int -> Int -> ContextCandidates -> (SelectedContext, [PolicyDrop])
selectContextTo costs tokenLimit initialTokens candidates =
  let (selected, drops) = go initialTokens [] candidates.candidateInputs
   in (SelectedContext selected, drops)
  where
    go estimated dropped inputs
      | estimated <= tokenLimit = (inputs, reverse dropped)
      | Just (memory, withoutMemory) <- dropOldestMemory (== "active") inputs =
          continue estimated (memoryDrop costs "memory.active" inputs withoutMemory memory) dropped withoutMemory
      | Just (source, savedTokens, degraded) <- degradeOneCompartment costs inputs =
          continue estimated (PolicyDrop source savedTokens) dropped degraded
      | oldest : rest <- inputs.transcript =
          let drop' = PolicyDrop "history.raw" (max 1 (estimateTextTokens oldest.renderedText))
           in continue estimated drop' dropped (inputs {transcript = rest})
      | Just (memory, withoutMemory) <- dropOldestMemory (== "permanent") inputs =
          continue estimated (memoryDrop costs "memory.permanent" inputs withoutMemory memory) dropped withoutMemory
      | otherwise = (inputs, reverse dropped)

    continue estimated drop' dropped inputs =
      go (max 0 (estimated - drop'.pdTokens)) (drop' : dropped) inputs

degradeOneCompartment :: ContextCostModel -> PromptInputs -> Maybe (Text, Int, PromptInputs)
degradeOneCompartment costs inputs = case filter ((/= TierP4) . (.contextTier)) inputs.compartments of
  [] -> Nothing
  candidates ->
    let selected = minimumBy (compare `on` degradationKey) candidates
        nextTier = succ selected.contextTier
        degraded = selected {contextTier = nextTier}
        compartments' =
          map
            (\compartment -> if compartment.contextCompartmentId == selected.contextCompartmentId then degraded else compartment)
            inputs.compartments
        after = inputs {compartments = compartments'}
        source =
          "history.compartment."
            <> T.toLower (compartmentTierText selected.contextTier)
            <> "->"
            <> T.toLower (compartmentTierText nextTier)
     in Just
          ( source,
            blockRemovalCost (costs.ccmCompartmentBlockTokens inputs) (costs.ccmCompartmentBlockTokens after),
            after
          )
  where
    degradationKey compartment =
      ( compartment.contextImportance,
        compartment.contextEndedAt,
        compartment.contextMaterializationVersion,
        compartment.contextCompartmentId
      )

memoryDrop :: ContextCostModel -> Text -> PromptInputs -> PromptInputs -> MemoryItem -> PolicyDrop
memoryDrop costs source before after memory =
  PolicyDrop source (max contentTokens blockTokens)
  where
    contentTokens = max 1 (estimateTextTokens memory.memContent)
    blockTokens = blockRemovalCost (costs.ccmMemoryBlockTokens before) (costs.ccmMemoryBlockTokens after)

blockRemovalCost :: Int -> Int -> Int
blockRemovalCost before after = max 1 (before - after + 8)

dropOldestMemory :: (Text -> Bool) -> PromptInputs -> Maybe (MemoryItem, PromptInputs)
dropOldestMemory lifecycleMatches inputs = case candidates of
  [] -> Nothing
  _ ->
    let (lane, oldest) = minimumBy (compare `on` candidateKey) candidates
        without = case lane of
          GroupMemory -> inputs {groupMemories = removeMemory oldest.memId inputs.groupMemories}
          UserMemory -> inputs {userMemories = removeMemory oldest.memId inputs.userMemories}
     in Just (oldest, without)
  where
    candidates =
      [(GroupMemory, memory) | memory <- inputs.groupMemories, lifecycleMatches memory.memLifecycle]
        <> [(UserMemory, memory) | memory <- inputs.userMemories, lifecycleMatches memory.memLifecycle]
    candidateKey (lane, memory) = (memory.memUpdatedAt, memory.memId, lane)

data MemoryLane = GroupMemory | UserMemory
  deriving stock (Show, Eq, Ord)

removeMemory :: MemoryId -> [MemoryItem] -> [MemoryItem]
removeMemory target = filter ((/= target) . (.memId))

applyBaseCompartmentTiers :: UTCTime -> [ContextCompartment] -> [ContextCompartment]
applyBaseCompartmentTiers now' compartments' =
  [ compartment {contextTier = baseTier distance compartment}
  | (distance, compartment) <- zip [count - 1, count - 2 .. 0] compartments'
  ]
  where
    count = length compartments'
    ageDays compartment =
      max 0 (realToFrac (diffUTCTime now' compartment.contextEndedAt) / 86400 :: Double)
    baseTier distance compartment
      | compartment.contextImportance >= 0.9 = TierP1
      | ageDays compartment <= 7 && compartment.contextConfidence >= 0.5 = TierP1
      | distance <= 3 && ageDays compartment <= 30 && compartment.contextConfidence >= 0.5 = TierP1
      | compartment.contextImportance >= 0.7 = TierP2
      | ageDays compartment <= 30 = TierP2
      | distance <= 15 && ageDays compartment <= 90 = TierP2
      | compartment.contextImportance >= 0.4 = TierP3
      | ageDays compartment <= 180 = TierP3
      | distance <= 63 && ageDays compartment <= 365 = TierP3
      | otherwise = TierP4

selectedCompartmentSummary :: ContextCompartment -> Maybe Text
selectedCompartmentSummary compartment = case compartment.contextTier of
  TierP1 -> Just compartment.contextSummaryP1
  TierP2 -> Just compartment.contextSummaryP2
  TierP3 -> Just compartment.contextSummaryP3
  TierP4 -> Nothing

compartmentTierText :: CompartmentTier -> Text
compartmentTierText = \case
  TierP1 -> "P1"
  TierP2 -> "P2"
  TierP3 -> "P3"
  TierP4 -> "P4"
