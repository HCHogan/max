{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Release-gate replay for unbounded context.  Historian cases use the exact
-- production prompt against a configured live profile; direct auto-recall
-- cases are deterministic and remain disconnected from prompt construction.
module Main (main) where

import Control.Monad (unless, when)
import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isSpace)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone, UTCTime, addUTCTime)
import Data.Version (makeVersion)
import Effectful
import Effectful.Log (LogLevel (LogAttention), runLog)
import Max.Config (AppConfig (..), appConfigParser)
import Max.Context (estimateMessagesTokens)
import Max.DB.History (HistoryItem (..), LedgerItem (..), MessageCursor (..))
import Max.Effects.LLM
  ( CallRecord (..),
    ChatCtx (..),
    LLM,
    TokenUsage (..),
    runLLM,
  )
import Max.EpisodeStore
  ( CaptureRun (..),
    CaptureRunId (..),
    CaptureValidationError (..),
    CitedSummary (..),
    EpisodeCapture (..),
    EpisodeMemoryProposal (..),
    SourceRange (..),
    captureValidationWarnings,
    validateEpisodeCapture,
  )
import Max.Historian (generateHistorianCapture, renderHistorianMessages, renderHistorianSourceLine)
import Max.HttpRuntime (newHttpRuntime)
import Max.Log (withCompactLogger)
import Max.MemoryStore (MemoryId (..))
import Max.ModelCatalog
  ( ModelCapabilities (..),
    contextInputBudget,
    defaultContextLimits,
    lookupModelCapabilities,
  )
import Max.Recall
  ( AutoRecallEligibility (..),
    RecallCandidate (..),
    RecallHit (..),
    selectDirectAutoHints,
  )
import OptEnvConf
import System.Exit (die, exitFailure)
import System.IO (hFlush, stdout)
import Text.Printf (printf)

data EvalOpts = EvalOpts
  { eoHistorianFixture :: !FilePath,
    eoRecallFixture :: !FilePath,
    eoCaseFilter :: !(Maybe Text),
    eoProfile :: !(Maybe Text),
    eoOfflineOnly :: !Bool,
    eoRuns :: !Int,
    eoMinPassRate :: !Double,
    eoMaxAveragePromptTokens :: !Int
  }

evalOptsParser :: Parser EvalOpts
evalOptsParser = do
  eoHistorianFixture <-
    setting
      [ help "JSONL Historian replay fixture",
        reader str,
        option,
        long "historian-fixture",
        metavar "FILE",
        value "context-eval/fixtures/historian.jsonl"
      ]
  eoRecallFixture <-
    setting
      [ help "JSONL direct auto-recall policy fixture",
        reader str,
        option,
        long "recall-fixture",
        metavar "FILE",
        value "context-eval/fixtures/recall.jsonl"
      ]
  eoCaseFilter <-
    optional $
      setting
        [ help "Run only Historian fixtures whose name contains this text",
          reader str,
          option,
          long "case",
          metavar "TEXT"
        ]
  eoProfile <-
    optional $
      setting
        [ help "Historian profile (default: memory.extract_profile)",
          reader str,
          option,
          long "eval-profile",
          metavar "NAME"
        ]
  eoOfflineOnly <-
    yesNoSwitch
      [ help "Validate fixtures and deterministic recall without live LLM calls",
        long "offline-only",
        value False
      ]
  eoRuns <-
    setting
      [ help "Repeat every live Historian fixture N times to measure stability",
        reader auto,
        option,
        long "runs",
        metavar "N",
        value 1
      ]
  eoMinPassRate <-
    setting
      [ help "Fail when Historian case pass rate is below this value",
        reader auto,
        option,
        long "min-pass-rate",
        metavar "F",
        value 1
      ]
  eoMaxAveragePromptTokens <-
    setting
      [ help "Optional provider-reported average Historian prompt-token ceiling (0 disables)",
        reader auto,
        option,
        long "max-average-prompt-tokens",
        metavar "N",
        value 0
      ]
  pure EvalOpts {..}

data FixtureMessage = FixtureMessage
  { fmId :: !Int64,
    fmUserId :: !Int64,
    fmName :: !Text,
    fmAt :: !UTCTime,
    fmText :: !Text,
    fmReplyTo :: !(Maybe Int64),
    fmEligible :: !Bool
  }

instance FromJSON FixtureMessage where
  parseJSON = withObject "historian message" $ \o ->
    FixtureMessage
      <$> o .: "id"
      <*> o .: "user_id"
      <*> o .: "name"
      <*> o .: "at"
      <*> o .: "text"
      <*> o .:? "reply_to"
      <*> (fromMaybe True <$> o .:? "eligible")

data ExpectedProposal = ExpectedProposal
  { epAction :: !Text,
    epScope :: !(Maybe Text),
    epUserId :: !(Maybe Int64),
    epCategories :: ![Text],
    epMemoryId :: !(Maybe Int64),
    epContentTermGroups :: ![[Text]],
    epEvidenceIds :: ![Int64]
  }

instance FromJSON ExpectedProposal where
  parseJSON = withObject "expected proposal" $ \o -> do
    category <- o .:? "category"
    categories <- fromMaybe [] <$> o .:? "categories"
    contentTerms <- fromMaybe [] <$> o .:? "content_terms"
    contentTermGroups <- fromMaybe [] <$> o .:? "content_term_groups"
    ExpectedProposal
      <$> o .: "action"
      <*> o .:? "scope"
      <*> o .:? "user_id"
      <*> pure (maybe categories (: categories) category)
      <*> o .:? "id"
      <*> pure (map (: []) contentTerms <> contentTermGroups)
      <*> (fromMaybe [] <$> o .:? "evidence_message_ids")

data HistorianExpect = HistorianExpect
  { heSummaryTermGroups :: ![[Text]],
    heForbiddenSummaryTerms :: ![Text],
    heP1EvidenceIds :: ![Int64],
    heProposals :: ![ExpectedProposal],
    heAllowAdditionalProposals :: !Bool
  }

instance FromJSON HistorianExpect where
  parseJSON = withObject "historian expectations" $ \o ->
    HistorianExpect
      <$> (fromMaybe [] <$> o .:? "summary_term_groups")
      <*> (fromMaybe [] <$> o .:? "forbidden_summary_terms")
      <*> (fromMaybe [] <$> o .:? "p1_evidence_message_ids")
      <*> (fromMaybe [] <$> o .:? "memory_proposals")
      <*> (fromMaybe False <$> o .:? "allow_additional_memory_proposals")

data HistorianFixture = HistorianFixture
  { hfName :: !Text,
    hfConversationId :: !Int64,
    hfNow :: !UTCTime,
    hfMessages :: ![FixtureMessage],
    hfExistingMemories :: ![Text],
    hfExpect :: !HistorianExpect
  }

instance FromJSON HistorianFixture where
  parseJSON = withObject "historian fixture" $ \o ->
    HistorianFixture
      <$> o .: "name"
      <*> (fromMaybe 900001 <$> o .:? "conversation_id")
      <*> o .: "now"
      <*> o .: "messages"
      <*> (fromMaybe ["[group memories]", "(none)"] <$> o .:? "existing_memories")
      <*> o .: "expect"

data RecallCandidateFixture = RecallCandidateFixture
  { rcfSource :: !Text,
    rcfKey :: !Text,
    rcfSnippet :: !Text,
    rcfLexical :: !(Maybe Double),
    rcfSemantic :: !(Maybe Double),
    rcfImportance :: !Double,
    rcfPinned :: !Bool,
    rcfPermanent :: !Bool,
    rcfAgeDays :: !Double
  }

instance FromJSON RecallCandidateFixture where
  parseJSON = withObject "recall candidate" $ \o ->
    RecallCandidateFixture
      <$> o .: "source"
      <*> o .: "key"
      <*> (fromMaybe "" <$> o .:? "snippet")
      <*> o .:? "lexical"
      <*> o .:? "semantic"
      <*> (fromMaybe 0 <$> o .:? "importance")
      <*> (fromMaybe False <$> o .:? "pinned")
      <*> (fromMaybe False <$> o .:? "permanent")
      <*> (fromMaybe 0 <$> o .:? "age_days")

data RecallFixture = RecallFixture
  { rfName :: !Text,
    rfNow :: !UTCTime,
    rfEligibility :: !Text,
    rfCandidates :: ![RecallCandidateFixture],
    rfExpectedKeys :: ![Text]
  }

instance FromJSON RecallFixture where
  parseJSON = withObject "recall fixture" $ \o ->
    RecallFixture
      <$> o .: "name"
      <*> o .: "now"
      <*> o .: "eligibility"
      <*> o .: "candidates"
      <*> o .: "expected_keys"

data HistorianResult = HistorianResult
  { hrName :: !Text,
    hrErrors :: ![Text],
    hrEstimatedPromptTokens :: !Int
  }

main :: IO ()
main = do
  usedRef <- newIORef Nothing
  (cfg, opts) <-
    runParser
      (makeVersion [0, 1, 0])
      "max-context-eval — unbounded-context release-gate replay"
      ((,) <$> appConfigParser usedRef <*> evalOptsParser)
  allHistorianFixtures <- loadJsonl "Historian" opts.eoHistorianFixture
  let historianFixtures = case opts.eoCaseFilter of
        Nothing -> allHistorianFixtures
        Just needle -> filter (T.isInfixOf (T.toCaseFold needle) . T.toCaseFold . (.hfName)) allHistorianFixtures
  recallFixtures <- loadJsonl "recall" opts.eoRecallFixture
  when (null historianFixtures) (die "Historian fixture is empty")
  when (null recallFixtures) (die "recall fixture is empty")

  recallFailures <- traverse evaluateRecallFixture recallFixtures
  reportRecall recallFailures
  unless (all (null . snd) recallFailures) exitFailure

  if opts.eoOfflineOnly
    then do
      let invalid = [(hfName fixture, validateHistorianFixture fixture) | fixture <- historianFixtures]
      reportFixtureValidation invalid
      unless (all (null . snd) invalid) exitFailure
      printf "offline-only: %d Historian fixtures parsed and %d recall fixtures passed\n" (length historianFixtures) (length recallFixtures)
    else do
      profile <- case opts.eoProfile <|> cfg.memoryExtractProfile of
        Just selectedProfile -> pure selectedProfile
        Nothing -> die "no Historian profile: pass --eval-profile or configure memory.extract_profile"
      let limits = maybe defaultContextLimits (.contextLimits) (lookupModelCapabilities profile cfg.llm)
          inputBudget = contextInputBudget limits False
      usageRef <- newIORef []
      callsRef <- newIORef []
      runtime <- newHttpRuntime
      let replayFixtures = concat (replicate (max 1 opts.eoRuns) historianFixtures)
      results <- withCompactLogger cfg.logColor Nothing $ \logger ->
        runEff
          . runLog "max-context-eval" logger LogAttention
          . runLLM runtime (collectUsage usageRef) (collectCall callsRef) cfg.llm
          $ traverse
            ( \(index, fixture) -> do
                result <- evaluateHistorianFixture profile inputBudget cfg.timezone fixture
                liftIO $ do
                  printf
                    "Historian replay %d/%d: %s %s\n"
                    (index :: Int)
                    (length replayFixtures)
                    (if null result.hrErrors then "PASS" else "FAIL" :: String)
                    (T.unpack result.hrName)
                  hFlush stdout
                pure result
            )
            (zip [1 ..] replayFixtures)
      usages <- reverse <$> readIORef usageRef
      calls <- reverse <$> readIORef callsRef
      reportHistorian profile results usages calls
      let passed = length (filter (null . (.hrErrors)) results)
          passRate = fromIntegral passed / fromIntegral (max 1 (length results))
          averageProviderPromptPerCapture :: Double
          averageProviderPromptPerCapture = fromIntegral (sum (map usagePrompt usages)) / fromIntegral (max 1 (length results))
          costPass =
            opts.eoMaxAveragePromptTokens <= 0
              || averageProviderPromptPerCapture <= fromIntegral opts.eoMaxAveragePromptTokens
      unless (passRate >= opts.eoMinPassRate && costPass && length usages == length calls) exitFailure

collectUsage :: IORef [TokenUsage] -> ChatCtx -> Text -> TokenUsage -> IO ()
collectUsage ref _ _ usage = modifyIORef' ref (usage :)

collectCall :: IORef [CallRecord] -> CallRecord -> IO ()
collectCall ref record = modifyIORef' ref (record :)

loadJsonl :: (FromJSON a) => String -> FilePath -> IO [a]
loadJsonl label path = do
  raw <- BS8.readFile path
  let numbered =
        [ (lineNo, eitherDecodeStrict' line)
        | (lineNo :: Int, line) <- zip [1 ..] (BS8.lines raw),
          not (BS8.all isSpace line)
        ]
      errors = [(lineNo, err) | (lineNo, Left err) <- numbered]
  unless (null errors) $
    die $
      unlines $
        (label <> " fixture has unparseable lines:")
          : [printf "  line %d: %s" lineNo err | (lineNo, err) <- errors]
  pure [decoded | (_, Right decoded) <- numbered]

validateHistorianFixture :: HistorianFixture -> [Text]
validateHistorianFixture fixture =
  ["messages must not be empty" | null fixture.hfMessages]
    <> ["message ids must be unique" | hasDuplicates (map (.fmId) fixture.hfMessages)]
    <> ["at least one message must be transcript eligible" | not (any (.fmEligible) fixture.hfMessages)]

evaluateHistorianFixture :: (LLM :> es) => Text -> Int -> TimeZone -> HistorianFixture -> Eff es HistorianResult
evaluateHistorianFixture profile inputBudget tz fixture = do
  let source = historianSource fixture
      run = fixtureRun fixture source profile
      sourceLines = [renderHistorianSourceLine tz entry.history | entry <- source, entry.transcriptEligible]
      messages = renderHistorianMessages tz fixture.hfNow run fixture.hfExistingMemories sourceLines inputBudget
      estimatedTokens = estimateMessagesTokens messages
      structuralErrors = validateHistorianFixture fixture
  generation <- generateHistorianCapture profile fixture.hfConversationId messages
  let errors = case generation of
        Left (_, failures) -> map renderValidation failures
        Right (_, capture) -> evaluateCapture fixture run source capture
  pure (HistorianResult fixture.hfName (structuralErrors <> errors) estimatedTokens)

evaluateCapture :: HistorianFixture -> CaptureRun -> [LedgerItem] -> EpisodeCapture -> [Text]
evaluateCapture fixture run source capture =
  validationErrors <> warningErrors <> summaryErrors <> proposalErrors
  where
    validationErrors = case validateEpisodeCapture run source capture of
      Left errors -> map renderValidation errors
      Right _ -> []
    warningErrors = case validateEpisodeCapture run source capture of
      Left _ -> []
      Right validated -> map (("proposal validation: " <>) . renderValidation) (captureValidationWarnings validated)
    summary = T.toCaseFold $ T.intercalate "\n" [capture.captureSummaryP1.summaryText, capture.captureSummaryP2.summaryText, capture.captureSummaryP3.summaryText]
    expectations = fixture.hfExpect
    summaryErrors =
      [ "summary missing one of: " <> T.intercalate " | " alternatives
      | alternatives <- expectations.heSummaryTermGroups,
        not (any ((`T.isInfixOf` summary) . T.toCaseFold) alternatives)
      ]
        <> ["summary contains forbidden term: " <> term | term <- expectations.heForbiddenSummaryTerms, T.toCaseFold term `T.isInfixOf` summary]
        <> [ "P1 evidence missing message " <> tshow messageId
           | messageId <- expectations.heP1EvidenceIds,
             messageId `notElem` capture.captureSummaryP1.evidenceMessageIds
           ]
    actual = capture.captureMemoryProposals
    expected = expectations.heProposals
    missing = [proposal | proposal <- expected, not (any (proposalMatches proposal) actual)]
    unexpected =
      [ proposal
      | proposal <- actual,
        not expectations.heAllowAdditionalProposals,
        not (any (`proposalMatches` proposal) expected)
      ]
    proposalErrors =
      ["missing memory proposal: " <> expectedProposalLabel proposal | proposal <- missing]
        <> ["unexpected memory proposal: " <> actualProposalLabel proposal | proposal <- unexpected]

proposalMatches :: ExpectedProposal -> EpisodeMemoryProposal -> Bool
proposalMatches expected actual =
  expected.epAction == action
    && maybe True (== scope) expected.epScope
    && maybe True (== userId) expected.epUserId
    && (null expected.epCategories || category `elem` expected.epCategories)
    && maybe True (== memoryId) expected.epMemoryId
    && all (\alternatives -> any ((`T.isInfixOf` T.toCaseFold content) . T.toCaseFold) alternatives) expected.epContentTermGroups
    && all (`elem` evidence) expected.epEvidenceIds
  where
    (action, scope, userId, category, memoryId, content, evidence) = proposalParts actual

proposalParts :: EpisodeMemoryProposal -> (Text, Text, Int64, Text, Int64, Text, [Int64])
proposalParts = \case
  ProposalAdd scope userId content category evidence ->
    ("add", scope, fromMaybe 0 userId, fromMaybe "" category, 0, content, evidence)
  ProposalUpdate mid _ content evidence ->
    ("update", "", 0, "", mid.unMemoryId, content, evidence)
  ProposalArchive mid _ evidence ->
    ("archive", "", 0, "", mid.unMemoryId, "", evidence)

expectedProposalLabel :: ExpectedProposal -> Text
expectedProposalLabel expected = expected.epAction <> maybe "" ("/" <>) expected.epScope <> maybe "" (("#" <>) . tshow) expected.epMemoryId

actualProposalLabel :: EpisodeMemoryProposal -> Text
actualProposalLabel proposal =
  let (action, scope, userId, category, memoryId, content, evidence) = proposalParts proposal
   in action
        <> "/"
        <> scope
        <> " subject="
        <> tshow userId
        <> " category="
        <> category
        <> " id="
        <> tshow memoryId
        <> " content="
        <> T.take 180 content
        <> " evidence="
        <> tshow evidence

renderValidation :: CaptureValidationError -> Text
renderValidation err = err.validationPath <> ": " <> err.validationMessage

historianSource :: HistorianFixture -> [LedgerItem]
historianSource fixture =
  [ LedgerItem
      (MessageCursor sequenceNumber)
      HistoryItem
        { messageId = message.fmId,
          userId = message.fmUserId,
          selfId = 999999,
          senderNickname = Just message.fmName,
          senderCard = Nothing,
          renderedText = message.fmText,
          receivedAt = message.fmAt,
          replyTo = message.fmReplyTo
        }
      message.fmEligible
  | (sequenceNumber, message) <- zip [1 ..] fixture.hfMessages
  ]

fixtureRun :: HistorianFixture -> [LedgerItem] -> Text -> CaptureRun
fixtureRun fixture source profile =
  CaptureRun
    { crId = CaptureRunId 1,
      crConversationId = fixture.hfConversationId,
      crExpectedCursor = MessageCursor 0,
      crRange =
        SourceRange
          { srStart = maybe (MessageCursor 0) (.cursor) (safeHead source),
            srEnd = maybe (MessageCursor 0) (.cursor) (safeLast source),
            srHash = "offline-fixture",
            srMessageCount = length source
          },
      crReason = "offline_eval",
      crStatus = "leased",
      crAttempt = 1,
      crLeaseOwner = Just "offline-eval",
      crLeaseExpiresAt = Nothing,
      crHistorianProfile = profile,
      crPromptVersion = "historian/v2",
      crSchemaVersion = 1,
      crReplacesCompartment = Nothing
    }

evaluateRecallFixture :: RecallFixture -> IO (Text, [Text])
evaluateRecallFixture fixture = do
  eligibility <- case fixture.rfEligibility of
    "direct" -> pure DirectUserTurn
    "group" -> pure GroupUserTurn
    "proactive" -> pure ProactiveTurn
    other -> die ("unknown recall eligibility in " <> T.unpack fixture.rfName <> ": " <> T.unpack other)
  let candidates = map (recallCandidate fixture.rfNow) fixture.rfCandidates
      actual = map (.rhDedupKey) (selectDirectAutoHints fixture.rfNow eligibility candidates)
      errors = ["expected " <> tshow fixture.rfExpectedKeys <> ", got " <> tshow actual | actual /= fixture.rfExpectedKeys]
  pure (fixture.rfName, errors)

recallCandidate :: UTCTime -> RecallCandidateFixture -> RecallCandidate
recallCandidate now fixture =
  RecallCandidate
    { rcSource = fixture.rcfSource,
      rcDedupKey = fixture.rcfKey,
      rcSnippet = if T.null fixture.rcfSnippet then fixture.rcfKey else fixture.rcfSnippet,
      rcOccurredAt = addUTCTime (negate (realToFrac fixture.rcfAgeDays * 86400)) now,
      rcPrincipalId = Nothing,
      rcMessageId = Nothing,
      rcEpisodeHandle = Nothing,
      rcMemoryId = Nothing,
      rcImportance = fixture.rcfImportance,
      rcLexicalScore = fixture.rcfLexical,
      rcSemanticScore = fixture.rcfSemantic,
      rcPinned = fixture.rcfPinned,
      rcPermanent = fixture.rcfPermanent
    }

reportRecall :: [(Text, [Text])] -> IO ()
reportRecall results = do
  let passed = length (filter (null . snd) results)
  printf "direct auto-recall policy: %d/%d fixtures passed (production injection remains disabled)\n" passed (length results)
  reportFailures results

reportFixtureValidation :: [(Text, [Text])] -> IO ()
reportFixtureValidation results = do
  let passed = length (filter (null . snd) results)
  printf "Historian fixture validation: %d/%d passed\n" passed (length results)
  reportFailures results

reportHistorian :: Text -> [HistorianResult] -> [TokenUsage] -> [CallRecord] -> IO ()
reportHistorian profile results usages calls = do
  let passed = length (filter (null . (.hrErrors)) results)
      estimated = map (.hrEstimatedPromptTokens) results
      promptTokens = map usagePrompt usages
      completionTokens = map usageCompletion usages
      durations = map (.crDurationMs) calls
  printf "Historian profile: %s\n" (T.unpack profile)
  printf "Historian quality: %d/%d cases passed (%.1f%%)\n" passed (length results) (100 * fromIntegral passed / fromIntegral (max 1 (length results)) :: Double)
  printf "estimated prompt tokens: total=%d average=%.1f\n" (sum estimated) (fromMaybe 0 (average estimated))
  printf "provider usage: captures=%d calls=%d repairs=%d prompt=%d completion=%d cached=%d\n" (length results) (length usages) (max 0 (length calls - length results)) (sum promptTokens) (sum completionTokens) (sum [fromMaybe 0 usage.usageCachedPrompt | usage <- usages])
  printf "provider averages/call: prompt=%.1f completion=%.1f latency_ms=%.1f\n" (fromMaybe 0 (average promptTokens)) (fromMaybe 0 (average completionTokens)) (fromMaybe 0 (average durations))
  printf "provider averages/capture: prompt=%.1f completion=%.1f\n" (perCapture promptTokens) (perCapture completionTokens)
  reportFailures [(result.hrName, result.hrErrors) | result <- results]
  where
    perCapture :: [Int] -> Double
    perCapture values = realToFrac (sum values) / fromIntegral (max 1 (length results))

reportFailures :: [(Text, [Text])] -> IO ()
reportFailures results =
  mapM_
    ( \(caseName, errors) -> unless (null errors) $ do
        printf "  FAIL %s\n" (T.unpack caseName)
        mapM_ (printf "    - %s\n" . T.unpack) errors
    )
    results

average :: (Real a) => [a] -> Maybe Double
average [] = Nothing
average values = Just (realToFrac (sum values) / fromIntegral (length values))

hasDuplicates :: (Ord a) => [a] -> Bool
hasDuplicates values = any (\item -> length (filter (== item) values) > 1) values

safeHead :: [a] -> Maybe a
safeHead = \case [] -> Nothing; item : _ -> Just item

safeLast :: [a] -> Maybe a
safeLast = \case [] -> Nothing; values -> Just (last values)

tshow :: (Show a) => a -> Text
tshow = T.pack . show
