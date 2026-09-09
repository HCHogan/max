module Max.DB.DebtSpec (spec) where

import Control.Monad (void)
import Data.Int (Int64)
import Data.Time (getCurrentTime, addUTCTime)
import Database.PostgreSQL.Simple
import Helpers (truncateAll)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.Debt
import Max.DB.Health (operationalChecks)
import Max.DB.TaskSpec (seed)
import Max.Platform.Types (CanonicalMessageId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "operational debt review" $ do
  it "retains terminal evidence, accepts only the observed revision, and reopens new failures" $ do
    (_, message, _) <- seed pool 900 1
    failRequest message
    plan <- observation
    let reviewed = plan {actor="operator",disposition=Just Accepted,reason="historical timeout accepted",evidence="incident review 15"}
    unreviewed `shouldReturn` 1
    withConn pool (`reviewDebt` reviewed) `shouldReturn` 1
    unreviewed `shouldReturn` 0
    withConn pool (\c -> query_ c "SELECT count(*) FROM conversation_requests WHERE disposition='failed'")
      `shouldReturn` [Only (1 :: Int64)]
    withConn pool (\c -> void $ execute_ c "UPDATE conversation_requests SET reason='new failure',updated_at=clock_timestamp()")
    unreviewed `shouldReturn` 1
    withConn pool (`reviewDebt` reviewed) `shouldThrow` anyIOException
    withConn pool (\c -> query_ c "SELECT count(*) FROM operational_debt_reviews")
      `shouldReturn` [Only (1 :: Int64)]

  it "rejects incomplete, out-of-scope, tampered and partially stale batches atomically" $ do
    (_, first, _) <- seed pool 900 1
    (_, second, _) <- seed pool 901 2
    failRequest first
    failRequest second
    plan <- observation
    withConn pool (`reviewDebt` plan) `shouldThrow` anyIOException
    let reviewed = plan {actor="operator",disposition=Just Accepted,reason="reviewed",evidence="external evidence"}
    withConn pool (`reviewDebt` (reviewed {scope=GlobalDebt})) `shouldThrow` anyIOException
    withConn pool (`reviewDebt` (reviewed {items=map (\item -> item {fingerprint="modified"}) plan.items})) `shouldThrow` anyIOException
    withConn pool (\c -> void $ execute c "UPDATE conversation_requests SET reason='changed' WHERE message_id=?" (Only second.unCanonicalMessageId))
    withConn pool (`reviewDebt` reviewed) `shouldThrow` anyIOException
    withConn pool (\c -> query_ c "SELECT count(*) FROM operational_debt_reviews")
      `shouldReturn` [Only (0 :: Int64)]

  it "requires actual resolution, supports revocation and keeps the audit immutable" $ do
    (_, message, _) <- seed pool 900 1
    failRequest message
    plan <- observation
    let reviewed = plan {actor="operator",disposition=Just Accepted,reason="accepted history",evidence="ticket 15"}
    withConn pool (`reviewDebt` (reviewed {disposition=Just Resolved})) `shouldThrow` anyIOException
    void $ withConn pool (`reviewDebt` reviewed)
    void $ withConn pool (`reviewDebt` (reviewed {disposition=Just Reopened}))
    unreviewed `shouldReturn` 1
    withConn pool (\c -> void $ execute_ c "UPDATE operational_debt_reviews SET actor='tampered'") `shouldThrow` anyException
    withConn pool (\c -> void $ execute_ c "DELETE FROM operational_debt_reviews") `shouldThrow` anyException
    withConn pool (\c -> void $ execute_ c "UPDATE conversation_requests SET disposition='answered',updated_at=clock_timestamp()")
    withConn pool (`reviewDebt` (reviewed {disposition=Just Resolved})) `shouldReturn` 1
    unreviewed `shouldReturn` 0
  where
    failRequest message = withConn pool $ \c -> void $ execute c
      "INSERT INTO conversation_requests(message_id,disposition,reason) VALUES (?,'failed','timeout') ON CONFLICT (message_id) DO UPDATE SET disposition='failed',reason='timeout',updated_at=clock_timestamp()"
      (Only message.unCanonicalMessageId)
    observation = do
      cutoff <- addUTCTime 1 <$> getCurrentTime
      withConn pool $ \c -> exportDebt c RequestFailed AllConversations cutoff
    unreviewed = withConn pool $ \c -> case [sql | (label,True,sql) <- operationalChecks,label=="request_failed_unreviewed"] of
      [sql] -> do
        [Only count] <- query_ c sql
        pure (count :: Int64)
      _ -> fail "missing request debt health gate"
