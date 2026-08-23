module Max.DB.QQBackfillSpec (spec) where

import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Helpers (insertRawMessage, testTime, truncateAll, withDb)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.QQBackfill
  ( QQBackfillEndpoint (..),
    QQBackfillResult (..),
    finishQQBackfillRun,
    listQQBackfillEndpoints,
    startQQBackfillRun,
  )
import Max.Platform.QQ (ensureQQEndpointFor)
import Max.Platform.Store (RegisteredEndpoint (..))
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "QQ reconnect backfill audit" $ do
  it "lists only registered QQ endpoints and reads the last observed message_seq" $ do
    _ <- insertRawMessage pool 9000 7777 2001 1000 testTime Nothing "before disconnect"
    withConn pool $ \connection -> do
      _ <-
        execute
          connection
          "UPDATE platform_events SET raw_payload = jsonb_build_object('message_seq', ?)"
          (Only ("41" :: Text))
      pure ()

    [candidate] <- withDb pool (listQQBackfillEndpoints 10)
    candidate.qbeEndpoint.compatibilityConversationId `shouldBe` 7777
    candidate.qbeNativeAccountId `shouldBe` "1000"
    candidate.qbeAnchorMessageSeq `shouldBe` Just "41"

  it "records terminal counts without presenting the run as a durable cursor" $ do
    _ <- withDb pool (ensureQQEndpointFor (UserId 1000) (GroupId 7777))
    [candidate] <- withDb pool (listQQBackfillEndpoints 10)
    runId <- withDb pool (startQQBackfillRun 3 candidate testTime 100)
    withDb pool $
      finishQQBackfillRun
        runId
        QQBackfillResult
          { qbrStatus = "partial",
            qbrFetchedCount = 8,
            qbrInsertedCount = 3,
            qbrDuplicateCount = 4,
            qbrSkippedAfterCutoff = 1,
            qbrParseFailureCount = 0,
            qbrStopReason = "some-history-requests-failed",
            qbrError = Just "anchor: timeout"
          }

    rows <- withConn pool $ \connection ->
      query
        connection
        "SELECT status, coverage, fetched_count, inserted_count, duplicate_count, \
        \       skipped_after_cutoff, stop_reason, finished_at IS NOT NULL \
        \  FROM qq_backfill_runs"
        ()
    (rows :: [(Text, Text, Int, Int, Int, Int, Text, Bool)])
      `shouldBe` [("partial", "best-effort-messages-only", 8, 3, 4, 1, "some-history-requests-failed", True)]
