module Max.EpisodeStoreSpec (spec) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Max.DB.History (HistoryItem (..), LedgerItem (..), MessageCursor (..))
import Max.EpisodeStore
import Test.Hspec

spec :: Spec
spec = describe "EpisodeCapture validation" $ do
  it "extracts a strict capture object from a fenced response" $ do
    parseEpisodeCapture fencedCapture `shouldBe` Right validCapture

  it "rejects summaries that cite filtered or out-of-range messages" $ do
    let bad =
          validCapture
            { captureSummaryP1 = CitedSummary "bad citation" [11, 12, 99]
            }
    expectValidationPath "summary_p1.evidence_message_ids" (validateEpisodeCapture captureRun source bad)

  it "rejects a source page that is not the run's exact range" $ do
    expectValidationPath "source_range" (validateEpisodeCapture captureRun (take 1 source) validCapture)

  it "keeps valid summaries while quarantining invalid memory proposals" $ do
    let capture =
          validCapture
            { captureMemoryProposals =
                [ ProposalAdd "group" (Just 42) "invalid scoped fact" Nothing [11],
                  ProposalAdd "user" (Just 42) "invalid relationship inference" (Just "relationship_context") [11]
                ]
            }
    case validateEpisodeCapture captureRun source capture of
      Left errors -> expectationFailure (show errors)
      Right validated -> do
        map (.validationPath) (captureValidationWarnings validated)
          `shouldBe` ["memory_proposals[0].user_id", "memory_proposals[1].category"]

captureRun :: CaptureRun
captureRun =
  CaptureRun
    { crId = CaptureRunId 1,
      crConversationId = 7,
      crExpectedCursor = MessageCursor 0,
      crRange = SourceRange (MessageCursor 1) (MessageCursor 2) (replicateText 64 "a") 2,
      crReason = "idle",
      crStatus = "leased",
      crAttempt = 1,
      crLeaseOwner = Just "test",
      crLeaseExpiresAt = Nothing,
      crHistorianProfile = "test",
      crPromptVersion = "historian/v1",
      crSchemaVersion = 1,
      crReplacesCompartment = Nothing
    }

source :: [LedgerItem]
source =
  [ ledger 1 11 42 True "hello",
    ledger 2 12 42 False "filtered command"
  ]

ledger :: Int64 -> Int64 -> Int64 -> Bool -> Text -> LedgerItem
ledger seqNo message speaker eligible body =
  LedgerItem
    (MessageCursor seqNo)
    (HistoryItem message speaker 1000 Nothing Nothing body testTime Nothing)
    eligible

validCapture :: EpisodeCapture
validCapture =
  EpisodeCapture
    { captureSummaryP1 = CitedSummary "full" [11],
      captureSummaryP2 = CitedSummary "compact" [11],
      captureSummaryP3 = CitedSummary "anchor" [11],
      captureImportance = 0.7,
      captureConfidence = 0.8,
      captureEpisodeKind = Ambient,
      captureMemoryProposals = []
    }

fencedCapture :: Text
fencedCapture =
  "```json\n{\"summary_p1\":{\"text\":\"full\",\"evidence_message_ids\":[11]},\"summary_p2\":{\"text\":\"compact\",\"evidence_message_ids\":[11]},\"summary_p3\":{\"text\":\"anchor\",\"evidence_message_ids\":[11]},\"importance\":0.7,\"confidence\":0.8,\"episode_kind\":\"ambient\",\"memory_proposals\":[]}\n```"

expectValidationPath :: Text -> Either [CaptureValidationError] a -> Expectation
expectValidationPath path = \case
  Left errors -> map (.validationPath) errors `shouldContain` [path]
  Right _ -> expectationFailure ("expected validation error at " <> show path)

replicateText :: Int -> Text -> Text
replicateText count = mconcat . replicate count

testTime :: UTCTime
testTime = read "2026-08-02 12:00:00 UTC"
