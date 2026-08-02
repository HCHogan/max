module Max.ContextMaterializationSpec (spec) where

import Control.Exception (SomeException)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), execute)
import Effectful.PostgreSQL (query)
import Helpers (insertRawMessage, truncateAll, withDb)
import Max.ContextMaterialization
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.History (LedgerItem, MessageCursor (..))
import Max.EpisodeStore
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "ContextMaterialization" $ do
  it "CAS-publishes an exact active projection and appends every revision" $ do
    compartment <- publishFixtureCompartment pool
    let item = MaterializedCompartment compartment 1 "p1"
        initial = MaterializationDraft fixtureEnd "context-policy/v2" [item] "initial_materialization"
    first <- withDb pool (publishContextMaterialization scope Nothing initial) >>= requireJust "first materialization"
    first.cmRevision `shouldBe` 1
    first.cmEndCursor `shouldBe` fixtureEnd
    first.cmItems `shouldBe` [item]

    withDb pool (publishContextMaterialization scope Nothing initial) `shouldReturn` Nothing
    let folded = initial {mdItems = [item {mcTier = "p2"}], mdReason = "high_water"}
    withDb pool (publishContextMaterialization scope (Just 999) folded) `shouldReturn` Nothing
    second <- withDb pool (publishContextMaterialization scope (Just 1) folded) >>= requireJust "second materialization"
    second.cmRevision `shouldBe` 2
    map (.mcTier) second.cmItems `shouldBe` ["p2"]

    versions <- withDb pool $ query "SELECT revision, reason FROM context_materialization_versions ORDER BY revision" ()
    (versions :: [(Int64, Text)]) `shouldBe` [(1, "initial_materialization"), (2, "high_water")]
    withConn pool (\conn -> execute conn "UPDATE context_materialization_versions SET reason = 'manual_rebuild' WHERE revision = 1" ())
      `shouldThrow` (\(_ :: SomeException) -> True)

  it "rejects stale projection versions before moving the raw boundary" $ do
    compartment <- publishFixtureCompartment pool
    let stale =
          MaterializationDraft
            fixtureEnd
            "context-policy/v2"
            [MaterializedCompartment compartment 999 "p1"]
            "initial_materialization"
    withDb pool (publishContextMaterialization scope Nothing stale)
      `shouldThrow` (\(_ :: SomeException) -> True)
    withDb pool (loadContextMaterialization scope) `shouldReturn` Nothing

scope :: ConversationScope
scope = conversationScopeFor (GroupId groupId)

publishFixtureCompartment :: DbPool -> IO CompartmentId
publishFixtureCompartment pool = do
  insertRawMessage pool 1001 groupId memberId botId testTime Nothing "first"
  insertRawMessage pool 1002 groupId botId botId testTime Nothing "second"
  end <- latestCursor pool
  run <-
    withDb
      pool
      ( enqueueCaptureRun
          scope
          (MessageCursor 0)
          end
          CaptureRequest
            { requestReason = CaptureIdle,
              requestHistorianProfile = "test",
              requestPromptVersion = "historian/test",
              requestSchemaVersion = 1
            }
      )
      >>= requireJust "capture run"
  lease <- withDb pool (claimCaptureRun "materialization-test" 60) >>= requireJust "capture lease"
  source <- withDb pool $ loadCaptureSource run
  let capture =
        EpisodeCapture
          { captureSummaryP1 = CitedSummary "full" [1001, 1002],
            captureSummaryP2 = CitedSummary "compact" [1001],
            captureSummaryP3 = CitedSummary "anchor" [1002],
            captureImportance = 0.5,
            captureConfidence = 1,
            captureEpisodeKind = Mixed,
            captureMemoryProposals = []
          }
  validated <- requireValid run source capture
  _ <- withDb pool $ recordCaptureGenerated lease "raw" capture []
  withDb pool $ publishCaptureRun scope lease validated

latestCursor :: DbPool -> IO MessageCursor
latestCursor pool = do
  rows <- withDb pool $ query "SELECT max(ingest_seq) FROM messages WHERE group_id = ?" (Only groupId)
  case rows :: [Only (Maybe Int64)] of
    Only (Just cursor) : _ -> pure (MessageCursor cursor)
    _ -> expectationFailure "missing cursor" >> pure (MessageCursor 0)

requireValid :: CaptureRun -> [LedgerItem] -> EpisodeCapture -> IO ValidatedEpisodeCapture
requireValid run source capture = case validateEpisodeCapture run source capture of
  Right value -> pure value
  Left errors -> expectationFailure (show errors) >> error "invalid capture"

requireJust :: String -> Maybe a -> IO a
requireJust label = \case
  Just value -> pure value
  Nothing -> expectationFailure ("missing " <> label) >> error ("missing " <> label)

groupId, memberId, botId :: Int64
groupId = 100
memberId = 2001
botId = 1000

testTime :: UTCTime
testTime = read "2026-08-02 12:00:00 UTC"

fixtureEnd :: MessageCursor
fixtureEnd = MessageCursor 2
