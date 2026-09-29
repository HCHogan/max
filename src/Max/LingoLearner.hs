-- | Background lingo learning (MaiBot-style expression and jargon learners).
-- The learner trails the Historian cursor, so it only reads ranges the
-- Historian has already settled; a fresh cursor starts at the beginning of the
-- ledger, which makes the first run a full-history backfill.  Conversations
-- are served one batch at a time in turn, so a long backfill in one group
-- does not delay learning in another.
module Max.LingoLearner
  ( lingoWorker,
    LingoStep (..),
    learnConversationOnce,
    inferDueJargon,
    skipFailingBatch,
    lingoBatchLines,
    lingoMinMemberLines,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, forever, unless)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope, conversationScopeFor, conversationStorageId)
import Max.DB.ConversationCursor (historianCursor, lingoCursor, loadCursor)
import Max.DB.History (HistoryItem (..), HistoryPage (..), LedgerItem (..), MessageCursor (..), bestName, fetchOldestPageThrough)
import Max.DB.Session (listSessions)
import Max.Effects.LLM (ChatCtx (..), ChatMessage (..), ChatResponse (..), LLM, chat)
import Max.Lingo.Policy
import Max.LingoStore
import Max.LLM.Failure (renderLLMFailure)
import Max.Session.Types (Session (..))
import Max.Worker (recovering)

-- | At most this many transcript lines go to the model at once; MaiBot learns
-- from similarly small windows, which keeps its 3–5 habits per batch sharp.
lingoBatchLines :: Int
lingoBatchLines = 60

-- | A settled range with fewer member lines than this waits for more talk.
lingoMinMemberLines :: Int
lingoMinMemberLines = 10

batchCharacters :: Int
batchCharacters = 6000

ledgerPageSize :: Int
ledgerPageSize = 500

inferencesPerStep :: Int
inferencesPerStep = 3

-- | A batch that fails this many times in a row is skipped rather than
-- blocking every later message of its conversation.
maxBatchFailures :: Int
maxBatchFailures = 3

data LingoStep
  = -- | A range was learned; the counts are accepted expressions and terms.
    LingoLearned !Int !Int
  | -- | Nothing settled and unread, or too little member talk yet.
    LingoWaiting
  | LingoFailed !Text
  deriving stock (Show, Eq)

data Failure = Failure
  { failedFrom :: !MessageCursor,
    failures :: !Int,
    retryAfter :: !UTCTime
  }

lingoWorker ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  Int ->
  Text ->
  Eff es ()
lingoWorker profile timeoutSeconds defaultModel = localDomain "lingo" $ do
  failuresRef <- liftIO (newIORef Map.empty)
  forever $ do
    progressed <- recovering "lingo pass" (learningPass failuresRef)
    unless progressed (liftIO (threadDelay 60_000_000))
  where
    learningPass failuresRef = do
      sessions <- listSessions defaultModel
      let scopes = Set.toList (Set.fromList [conversationScopeFor session.groupId | session <- sessions])
      now <- liftIO getCurrentTime
      steps <- forM scopes $ \scope -> do
        blocked <- liftIO (coolingDown failuresRef scope now)
        if blocked then pure False else learnScope failuresRef scope
      pure (or steps)

    learnScope failuresRef scope = do
      step <- learnConversationOnce profile timeoutSeconds scope
      inferred <- inferDueJargon profile timeoutSeconds scope
      case step of
        LingoLearned expressions terms -> do
          liftIO (clearFailure failuresRef scope)
          logInfo "lingo: range learned" $
            object ["group_id" .= conversationStorageId scope, "expressions" .= expressions, "jargon" .= terms, "inferred" .= inferred]
          pure True
        LingoWaiting -> pure (inferred > 0)
        LingoFailed err -> do
          from <- loadCursor scope lingoCursor
          now <- liftIO getCurrentTime
          count <- liftIO (recordFailure failuresRef scope from now)
          logAttention "lingo: batch failed" $
            object ["group_id" .= conversationStorageId scope, "consecutive_failures" .= count, "error" .= err]
          if count >= maxBatchFailures
            then do
              skipped <- skipFailingBatch scope from
              liftIO (clearFailure failuresRef scope)
              logAttention "lingo: skipped a batch after repeated failures" $
                object ["group_id" .= conversationStorageId scope, "from_ingest_seq" .= from.ingestSeq, "skipped" .= skipped]
              pure skipped
            else pure False

type Failures = IORef (Map Int64 Failure)

-- | Failures back off per conversation: 5, 10, 20, then 40 minutes.
recordFailure :: Failures -> ConversationScope -> MessageCursor -> UTCTime -> IO Int
recordFailure ref scope from now = atomicModifyIORef' ref $ \m ->
  let key = conversationStorageId scope
      count = case Map.lookup key m of
        Just previous | previous.failedFrom == from -> previous.failures + 1
        _ -> 1
      delay = 300 * 2 ^ min 3 (count - 1) :: Int
   in (Map.insert key (Failure from count (addUTCTime (fromIntegral delay) now)) m, count)

clearFailure :: Failures -> ConversationScope -> IO ()
clearFailure ref scope = atomicModifyIORef' ref (\m -> (Map.delete (conversationStorageId scope) m, ()))

coolingDown :: Failures -> ConversationScope -> UTCTime -> IO Bool
coolingDown ref scope now =
  maybe False ((> now) . (.retryAfter)) . Map.lookup (conversationStorageId scope) <$> readIORef ref

-- | Advance past the batch that keeps failing, learning nothing from it.
skipFailingBatch :: (WithConnection :> es, IOE :> es) => ConversationScope -> MessageCursor -> Eff es Bool
skipFailingBatch scope from = do
  settled <- loadCursor scope historianCursor
  (items, _) <- collectBatch scope from settled
  case lastMaybe items of
    Nothing -> pure False
    Just entry -> recordLingoBatch scope from entry.cursor [] []

-- | Learn the next settled range of one conversation, if it is ready.
learnConversationOnce ::
  (LLM :> es, WithConnection :> es, IOE :> es) =>
  Text ->
  Int ->
  ConversationScope ->
  Eff es LingoStep
learnConversationOnce profile timeoutSeconds scope = do
  learned <- loadCursor scope lingoCursor
  settled <- loadCursor scope historianCursor
  if learned >= settled
    then pure LingoWaiting
    else do
      (items, reachedEnd) <- collectBatch scope learned settled
      redacted <- redactedAmong [entry.history.canonicalId | entry <- items]
      let sources =
            zipWith
              toSource
              [1 ..]
              [ entry.history
              | entry <- items,
                entry.transcriptEligible,
                entry.history.canonicalId `Set.notMember` redacted,
                not (T.null (T.strip (cleanLingoLine entry.history.renderedText)))
              ]
          members = length (filter (not . (.lsFromBot)) sources)
      -- A settled range with no rows of this conversation has nothing to
      -- learn; move past it instead of re-reading it every pass.
      decide sources members reachedEnd learned (maybe settled (.cursor) (lastMaybe items))
  where
    decide sources members reachedEnd learned end
      | end == learned = pure LingoWaiting
      | null sources && reachedEnd = record learned end [] []
      | reachedEnd && members < lingoMinMemberLines = pure LingoWaiting
      | members == 0 = record learned end [] []
      | otherwise = do
          response <- chat (lingoCtx scope timeoutSeconds) profile [MsgSystem lingoLearnerSystem, MsgUser (renderLingoSources sources)] []
          case response of
            Left err -> pure (LingoFailed ("provider: " <> renderLLMFailure err))
            Right (ContentResp raw) -> case parseLearnedBatch raw of
              Left err -> pure (LingoFailed ("invalid response: " <> T.pack err))
              Right batch -> record learned end (acceptExpressions sources batch.lbExpressions) (acceptJargon sources batch.lbJargon)
            Right (InterruptedResp _ _) -> pure (LingoFailed "provider interrupted")
            Right ToolCallsResp {} -> pure (LingoFailed "unexpected tool calls")
    record from end expressions terms = do
      stored <- recordLingoBatch scope from end expressions terms
      pure (if stored then LingoLearned (length expressions) (length terms) else LingoWaiting)
    toSource index history =
      LingoSource
        { lsIndex = index,
          lsMessageId = history.canonicalId,
          lsPrincipal = history.authorPrincipalId,
          lsName = bestName history,
          lsFromBot = history.fromBot,
          lsText = history.renderedText
        }

-- | Read forward from the learner cursor up to the settled cursor until the
-- batch has enough lines or characters.  Rows that are not transcript lines
-- still move the batch end, so they are never read again.
collectBatch ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  MessageCursor ->
  Eff es ([LedgerItem], Bool)
collectBatch scope from through = go from 0 0 []
  where
    go cursor lines' chars acc = do
      page <- fetchOldestPageThrough scope cursor through ledgerPageSize
      let (taken, full) = takeLines lines' chars page.items
          acc' = acc <> taken
      case lastMaybe taken of
        _ | full -> pure (acc', False)
        Just entry | page.hasMore -> go entry.cursor (lines' + countLines taken) (chars + countChars taken) acc'
        _ -> pure (acc', True)
    takeLines _ _ [] = ([], False)
    takeLines lines' chars (entry : rest)
      | lines' + 1 >= lingoBatchLines || chars + cost >= batchCharacters, eligible = ([entry], True)
      | otherwise =
          let (more, full) = takeLines (lines' + fromEnum eligible) (chars + cost) rest
           in (entry : more, full)
      where
        eligible = entry.transcriptEligible
        cost = if eligible then T.length entry.history.renderedText else 0
    countLines = length . filter (.transcriptEligible)
    countChars = sum . map (\entry -> if entry.transcriptEligible then T.length entry.history.renderedText else 0)

-- | Infer meanings for a few terms that crossed an inference threshold.  An
-- answer that cannot be read counts as "no information" at this count; a
-- provider failure leaves the term due and ends the step, so an outage costs
-- one call per pass rather than one per term.
inferDueJargon ::
  (LLM :> es, WithConnection :> es, IOE :> es) =>
  Text ->
  Int ->
  ConversationScope ->
  Eff es Int
inferDueJargon profile timeoutSeconds scope = do
  candidates <- jargonAwaitingInference scope 50
  go 0 (take inferencesPerStep [c | c <- candidates, needsInference c.jcHits c.jcInferredHits c.jcSpeakers])
  where
    go done [] = pure done
    go done (candidate : rest) =
      infer candidate >>= \case
        Nothing -> pure done
        Just inference -> do
          recordJargonInference candidate.jcId candidate.jcHits inference
          go (done + 1) rest
    ask prompt = do
      response <- chat (lingoCtx scope timeoutSeconds) profile [MsgUser prompt] []
      pure $ case response of
        Right (ContentResp raw) -> Just raw
        _ -> Nothing
    unknown = JargonInference Nothing False
    infer candidate = do
      generalRaw <- ask (generalMeaningPrompt candidate.jcTerm)
      case generalRaw of
        Nothing -> pure Nothing
        Just raw -> do
          let general = fromMaybe "（不确定）" (parseGeneralMeaning raw)
          fmap (fromMaybe unknown . parseContextualMeaning) <$> ask (contextualMeaningPrompt candidate.jcTerm candidate.jcContexts general)

lingoCtx :: ConversationScope -> Int -> ChatCtx
lingoCtx scope timeoutSeconds =
  ChatCtx
    "lingo"
    (Just (conversationStorageId scope))
    Nothing
    (Just (max 1 timeoutSeconds))
    (Just [])
    Nothing
    Nothing

lastMaybe :: [a] -> Maybe a
lastMaybe = \case
  [] -> Nothing
  xs -> Just (last xs)
