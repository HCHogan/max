module Max.DB.TransactionSpec (spec) where

import Control.Exception (Exception, throwIO, try)
import Database.PostgreSQL.Simple (Only (..), query)
import Effectful (liftIO)
import Effectful.PostgreSQL (execute)
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.Transaction qualified as Transaction
import Test.Hspec

data RollbackProbe = RollbackProbe
  deriving stock (Eq, Show)

instance Exception RollbackProbe

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.DB.Transaction" $ do
  it "pins pooled statements to the transaction connection and rolls them back together" $ do
    result <-
      try
        ( withDb pool $
            Transaction.withTransaction $ do
              _ <-
                execute
                  "INSERT INTO conversations (conversation_kind, title) VALUES ('group', 'rollback probe')"
                  ()
              liftIO (throwIO RollbackProbe)
        ) :: IO (Either RollbackProbe ())
    result `shouldBe` Left RollbackProbe
    rows <-
      withConn pool $ \connection ->
        query connection "SELECT count(*) FROM conversations WHERE title = 'rollback probe'" ()
    (rows :: [Only Int]) `shouldBe` [Only 0]
