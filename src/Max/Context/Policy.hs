-- |
-- Pure deterministic selection over a collected context snapshot.  The
-- renderer supplies block-local cost functions once; the policy never invokes
-- the complete prompt renderer while degrading candidates.
module Max.Context.Policy
  ( ContextCostModel (..),
    PolicyDrop (..),
    selectContextTo,
    limitSummaryTokens,
  )
where

import Data.Function (on)
import Data.List (minimumBy)
import Data.Text (Text)
import Max.Context (estimateTextTokens)
import Max.Context.Types
import Max.History.Types (HistoryItem (..))
import Max.Memory.Types (MemoryId, MemoryItem (..))

data ContextCostModel = ContextCostModel
  { ccmMemoryBlockTokens :: PromptInputs -> Int,
    ccmCompartmentBlockTokens :: PromptInputs -> Int,
    ccmRecentTurnTokens :: Text -> Int
  }

data PolicyDrop = PolicyDrop
  { pdSource :: !Text,
    pdTokens :: !Int
  }

selectContextTo :: ContextCostModel -> Int -> Int -> ContextSnapshot -> (SelectedContext, [PolicyDrop])
selectContextTo costs tokenLimit initialTokens candidates =
  let (selected, drops) = go initialTokens [] candidates.csInputs
   in (SelectedContext selected, drops)
  where
    go estimated dropped inputs
      | estimated <= tokenLimit = (inputs, reverse dropped)
      | Just (memory, withoutMemory) <- dropOldestMemory (== "active") inputs =
          continue estimated (memoryDrop costs "memory.active" inputs withoutMemory memory) dropped withoutMemory
      | Just (line, withoutTurn) <- dropOldestRecentTurn inputs =
          continue estimated (PolicyDrop "turn.recent" (max 1 (costs.ccmRecentTurnTokens line))) dropped withoutTurn
      | Just (savedTokens, withoutSummary) <- dropOldestSummary costs inputs =
          continue estimated (PolicyDrop "history.summary" savedTokens) dropped withoutSummary
      | oldest : rest <- inputs.transcript =
          let drop' = PolicyDrop "history.raw" (max 1 (estimateTextTokens oldest.renderedText))
           in continue estimated drop' dropped (inputs {transcript = rest})
      | Just (memory, withoutMemory) <- dropOldestMemory (== "permanent") inputs =
          continue estimated (memoryDrop costs "memory.permanent" inputs withoutMemory memory) dropped withoutMemory
      | otherwise = (inputs, reverse dropped)

    continue estimated drop' dropped inputs =
      go (max 0 (estimated - drop'.pdTokens)) (drop' : dropped) inputs

-- | Retain the newest chronological suffix under the summary budget.
limitSummaryTokens :: Int -> ContextSnapshot -> (ContextSnapshot, [PolicyDrop])
limitSummaryTokens tokenLimit candidates =
  let inputs = candidates.csInputs
      rows = inputs.compartments
      costs = map ((64 +) . estimateTextTokens . (.contextSummary)) rows
      (retained, removed) = trim (sum costs) (zip rows costs) []
   in (ContextSnapshot (inputs {compartments = retained}), removed)
  where
    trim used ((row, tokens) : rest) removed
      | used > max 0 tokenLimit = trim (used - tokens) rest (PolicyDrop "history.summary" tokens : removed)
      | otherwise = (row : map fst rest, reverse removed)
    trim _ [] removed = ([], reverse removed)

dropOldestSummary :: ContextCostModel -> PromptInputs -> Maybe (Int, PromptInputs)
dropOldestSummary costs inputs = case inputs.compartments of
  [] -> Nothing
  _ : rest ->
    let after = inputs {compartments = rest}
     in Just (blockRemovalCost (costs.ccmCompartmentBlockTokens inputs) (costs.ccmCompartmentBlockTokens after), after)

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

dropOldestRecentTurn :: PromptInputs -> Maybe (Text, PromptInputs)
dropOldestRecentTurn inputs = case reverse inputs.recentTurns of
  [] -> Nothing
  oldest : rest -> Just (oldest, inputs {recentTurns = reverse rest})
