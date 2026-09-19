-- |
-- Pure deterministic selection over a collected context snapshot.  The
-- renderer supplies block-local cost functions once; the policy never invokes
-- the complete prompt renderer while degrading candidates.
module Max.Context.Policy
  ( ContextCostModel (..),
    PolicyDrop (..),
    selectContextTo,
    limitSummaryTokens,
    applyBaseCompartmentTiers,
  )
where

import Data.Function (on)
import Data.List (find, minimumBy, sortOn)
import Data.Maybe (isJust, mapMaybe)
import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime)
import Max.Context (estimateTextTokens)
import Max.Context.Types
import Max.Episode.Types (EpisodeHandle)
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
      | Just (source, withoutSummary) <- degradeSummary inputs =
          continue estimated (PolicyDrop source (blockRemovalCost (costs.ccmCompartmentBlockTokens inputs) (costs.ccmCompartmentBlockTokens withoutSummary))) dropped withoutSummary
      | oldest : rest <- inputs.transcript =
          let drop' = PolicyDrop "history.raw" (max 1 (estimateTextTokens oldest.renderedText))
           in continue estimated drop' dropped (inputs {transcript = rest})
      | Just (memory, withoutMemory) <- dropOldestMemory (== "permanent") inputs =
          continue estimated (memoryDrop costs "memory.permanent" inputs withoutMemory memory) dropped withoutMemory
      | otherwise = (inputs, reverse dropped)

    continue estimated drop' dropped inputs =
      go (max 0 (estimated - drop'.pdTokens)) (drop' : dropped) inputs

-- | Recent episodes start detailed; older, less important episodes start compact.
applyBaseCompartmentTiers :: UTCTime -> [ContextCompartment] -> [ContextCompartment]
applyBaseCompartmentTiers now rows = mapMaybe select (zip [length rows - 1, length rows - 2 .. 0] rows)
  where
    select (distance, row) = do
      preferred <- baseTier distance row
      tier <- find (\candidate -> isJust (compartmentSummaryAt candidate row)) (reverse [TierP1 .. preferred])
      pure row {contextTier = tier}
    baseTier distance row
      | distance < 2 && age <= 7 && row.contextConfidence >= 0.5 = Just TierP1
      | row.contextImportance >= 0.7 || age <= 30 || (distance < 16 && age <= 90) = Just TierP2
      | row.contextImportance >= 0.4 || age <= 180 || (distance < 64 && age <= 365) = Just TierP3
      | otherwise = Nothing
      where
        age = realToFrac (diffUTCTime now row.contextEndedAt) / 86400 :: Double

-- | Keep summary growth from displacing the other context sources.
limitSummaryTokens :: Int -> ContextSnapshot -> (ContextSnapshot, [PolicyDrop])
limitSummaryTokens tokenLimit candidates =
  let inputs = candidates.csInputs
      rows = zip [0 :: Int ..] inputs.compartments
      (selected, drops) = trim (sum (map (summaryCost . snd) rows)) (sortOn (summaryPriority . snd) rows) []
   in (ContextSnapshot (inputs {compartments = map snd (sortOn fst selected)}), reverse drops)
  where
    summaryCost row = 64 + estimateTextTokens (selectedCompartmentSummary row)
    trim used rows drops
      | used <= max 0 tokenLimit = (rows, drops)
    trim used ((index, row) : rest) drops =
      let lower = smallerSummary row
          saved = summaryCost row - maybe 0 summaryCost lower
          rows = maybe rest (\next -> (index, next) : rest) lower
       in trim (used - saved) rows (PolicyDrop (summaryTransition row lower) saved : drops)
    trim _ [] drops = ([], drops)

degradeSummary :: PromptInputs -> Maybe (Text, PromptInputs)
degradeSummary inputs = case inputs.compartments of
  [] -> Nothing
  rows ->
    let row = minimumBy (compare `on` summaryPriority) rows
        lower = smallerSummary row
        replace candidate
          | candidate.contextExpandHandle /= row.contextExpandHandle = Just candidate
          | otherwise = lower
     in Just (summaryTransition row lower, inputs {compartments = mapMaybe replace rows})

summaryPriority :: ContextCompartment -> (Double, UTCTime, EpisodeHandle)
summaryPriority row = (row.contextImportance, row.contextEndedAt, row.contextExpandHandle)

smallerSummary :: ContextCompartment -> Maybe ContextCompartment
smallerSummary row =
  (\tier -> row {contextTier = tier}) <$> find cheaper (filter (> row.contextTier) [TierP1 .. TierP3])
  where
    cheaper tier = case compartmentSummaryAt tier row of
      Nothing -> False
      Just summary -> estimateTextTokens summary < estimateTextTokens (selectedCompartmentSummary row)

summaryTransition :: ContextCompartment -> Maybe ContextCompartment -> Text
summaryTransition before after =
  "history.summary." <> compartmentTierText before.contextTier <> "->" <> maybe "omitted" (compartmentTierText . (.contextTier)) after

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
