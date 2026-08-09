module Max.TurnReplaySpec (spec) where

import Data.Int (Int64)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Max.Effects.LLM (ChatMessage (..))
import Max.Turn.Replay
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..), TurnOrdinal (..))
import Test.Hspec

now' :: UTCTime
now' = UTCTime (fromGregorian 2026 8 9) (secondsToDiffTime (12 * 3600))

catalog :: Text
catalog = "cafe0000"

env :: ReplayEnvironment
env =
  ReplayEnvironment
    { reNow = now',
      reProfile = "deepseek",
      rePromptMajor = 2,
      reCatalogFingerprint = catalog,
      reChainTokenBudget = 1000
    }

-- | A candidate that passes every non-budget check.
healthy :: Int64 -> ReplayCandidate
healthy n =
  ReplayCandidate
    { rcTurn = AgentTurnRef (AgentTurnId n) (TurnOrdinal n),
      rcProfile = Just "deepseek",
      rcPromptMajor = 2,
      rcCatalogFingerprint = Just catalog,
      rcArchiveSha = Just "deadbeef",
      rcArchiveCreatedAt = Just (addUTCTime (-3600) now'),
      rcArchiveExpiresAt = Just (addUTCTime 3600 now'),
      rcTriggerCanonicalId = Just (1000 + n),
      rcTriggerLine = Just "[12:00 hank #1001]: 画个图",
      rcOutputCanonicalIds = [2000 + n]
    }


-- Cheap by default so the budget never accidentally decides an outcome; the
-- bulky variant exists only for the budget test.
bulky :: Either ReplayReject [ChatMessage]
bulky = Right [MsgAssistant (T.replicate 1500 "x")]

loaded :: Either ReplayReject [ChatMessage]
loaded = Right [MsgAssistant "ok"]

spec :: Spec
spec = do
  describe "replay validity predicate" $ do
    it "admits a candidate whose whole environment still matches" $
      candidateRejection env (healthy 1) `shouldBe` Nothing

    it "refuses a turn that never captured an archive" $
      candidateRejection env (healthy 1) {rcArchiveSha = Nothing}
        `shouldBe` Just RejectNoArchive

    it "refuses an archive whose retention already elapsed" $
      candidateRejection env (healthy 1) {rcArchiveExpiresAt = Just (addUTCTime (-1) now')}
        `shouldBe` Just RejectArchiveExpired

    it "refuses reasoning older than the provider validity window" $ do
      let old = addUTCTime (negate (fromIntegral providerValidityDays * 86400 + 60)) now'
      candidateRejection env (healthy 1) {rcArchiveCreatedAt = Just old}
        `shouldBe` Just RejectProviderWindow

    it "refuses another model's opaque bytes" $
      candidateRejection env (healthy 1) {rcProfile = Just "anthropic"}
        `shouldBe` Just RejectProfileChanged

    it "refuses a turn that ran under a different host prompt contract" $
      candidateRejection env (healthy 1) {rcPromptMajor = 1}
        `shouldBe` Just RejectPromptMajorChanged

    it "refuses archived calls against a drifted tool catalog" $
      candidateRejection env (healthy 1) {rcCatalogFingerprint = Just "0000beef"}
        `shouldBe` Just RejectCatalogChanged

    it "treats a missing environment fact as a rejection, never as a pass" $ do
      candidateRejection env (healthy 1) {rcProfile = Nothing}
        `shouldBe` Just RejectProfileChanged
      candidateRejection env (healthy 1) {rcCatalogFingerprint = Nothing}
        `shouldBe` Just RejectCatalogChanged
      candidateRejection env (healthy 1) {rcArchiveExpiresAt = Nothing}
        `shouldBe` Just RejectArchiveExpired
      candidateRejection env (healthy 1) {rcArchiveCreatedAt = Nothing}
        `shouldBe` Just RejectProviderWindow

    it "refuses a turn whose own trigger row no longer renders" $
      candidateRejection env (healthy 1) {rcTriggerLine = Nothing}
        `shouldBe` Just RejectTriggerUnrenderable

  describe "fork-chain compression" $ do
    it "returns admitted segments oldest first from a newest-first chain" $ do
      let plan =
            planReplay
              env
              [ (healthy 3, loaded),
                (healthy 2, loaded),
                (healthy 1, loaded)
              ]
      map (.rsTurn.atrTurnOrdinal) plan.rpSegments
        `shouldBe` map TurnOrdinal [1, 2, 3]
      plan.rpStoppedBecause `shouldBe` Nothing
      plan.rpEstimatedTokens `shouldSatisfy` (> 0)

    it "keeps the verbatim run contiguous by stopping at the first rejection" $ do
      -- t#2 is the drifted one; t#1 behind it stays digest even though it
      -- would pass on its own, because a hole mid-chain is worse than depth.
      let plan =
            planReplay
              env
              [ (healthy 3, loaded),
                ((healthy 2) {rcPromptMajor = 1}, loaded),
                (healthy 1, loaded)
              ]
      map (.rsTurn.atrTurnOrdinal) plan.rpSegments `shouldBe` [TurnOrdinal 3]
      plan.rpStoppedBecause `shouldBe` Just RejectPromptMajorChanged

    it "spends the chain budget newest first and drops the older tail" $ do
      let plan =
            planReplay
              env
              [ (healthy 3, bulky),
                (healthy 2, bulky),
                (healthy 1, loaded)
              ]
      map (.rsTurn.atrTurnOrdinal) plan.rpSegments `shouldBe` [TurnOrdinal 3]
      plan.rpStoppedBecause `shouldBe` Just RejectChainBudget
      plan.rpEstimatedTokens `shouldSatisfy` (<= reChainTokenBudget env)

    it "stops on an unreadable archive rather than skipping past it" $ do
      let plan =
            planReplay
              env
              [ (healthy 3, loaded),
                (healthy 2, Left RejectArchiveUnreadable),
                (healthy 1, loaded)
              ]
      map (.rsTurn.atrTurnOrdinal) plan.rpSegments `shouldBe` [TurnOrdinal 3]
      plan.rpStoppedBecause `shouldBe` Just RejectArchiveUnreadable

    it "produces no segments at all when the target itself is invalid" $ do
      let plan = planReplay env [((healthy 3) {rcArchiveSha = Nothing}, loaded)]
      null plan.rpSegments `shouldBe` True
      plan.rpStoppedBecause `shouldBe` Just RejectNoArchive

  describe "ledger dedup" $ do
    it "covers exactly the triggers and outputs of admitted segments" $ do
      let plan =
            planReplay
              env
              [ (healthy 3, loaded),
                ((healthy 2) {rcProfile = Just "anthropic"}, loaded)
              ]
      -- t#3 contributes its trigger #1003 and its output #2003; the rejected
      -- t#2 contributes nothing, so its rows stay in the ordinary window.
      planCoveredCanonicalIds plan `shouldBe` Set.fromList [1003, 2003]

    it "covers nothing when the plan is empty" $
      planCoveredCanonicalIds (planReplay env []) `shouldBe` Set.empty

    it "opens each segment with its own trigger before the archived items" $ do
      let plan = planReplay env [(healthy 3, Right [MsgAssistant "done"])]
      case planReplayMessages plan of
        [MsgUser line, MsgAssistant reply] -> do
          line `shouldBe` "[12:00 hank #1001]: 画个图"
          reply `shouldBe` "done"
        other -> expectationFailure ("unexpected replay shape: " <> show (length other))

