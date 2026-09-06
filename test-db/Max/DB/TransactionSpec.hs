module Max.DB.TransactionSpec (spec) where

import Control.Exception (Exception, throwIO, try)
import Database.PostgreSQL.Simple (Only (..), query)
import Effectful (liftIO)
import Effectful.Exception qualified as EffException
import Effectful.PostgreSQL (execute)
import Effectful.PostgreSQL qualified as DB
import Helpers (truncateAll, withDb)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.Transaction qualified as Transaction
import Test.Hspec

data RollbackProbe = RollbackProbe
  deriving stock (Eq, Show)

instance Exception RollbackProbe

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.DB.Transaction" $ do
  it "keeps a standalone read snapshot stable across a concurrent commit" $ do
    (snapshotBefore, snapshotAfter) <- withDb pool $ Transaction.withReadSnapshot $ do
      first <- DB.query "SELECT count(*) FROM conversations WHERE title='snapshot probe'" ()
      _ <- liftIO . withDb pool $ execute "INSERT INTO conversations(conversation_kind,title) VALUES('group','snapshot probe')" ()
      second <- DB.query "SELECT count(*) FROM conversations WHERE title='snapshot probe'" ()
      pure (first, second)
    (snapshotBefore :: [Only Int]) `shouldBe` [Only 0]
    (snapshotAfter :: [Only Int]) `shouldBe` [Only 0]
    committed <- withDb pool $ DB.query "SELECT count(*) FROM conversations WHERE title='snapshot probe'" ()
    (committed :: [Only Int]) `shouldBe` [Only 1]

  it "rejects writes in a standalone read snapshot" $ do
    withDb pool (Transaction.withReadSnapshot $ execute "INSERT INTO conversations(conversation_kind,title) VALUES('group','forbidden read write')" ()) `shouldThrow` anyException
    rows <- withDb pool $ DB.query "SELECT count(*) FROM conversations WHERE title='forbidden read write'" ()
    (rows :: [Only Int]) `shouldBe` [Only 0]

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
        ) ::
        IO (Either RollbackProbe ())
    result `shouldBe` Left RollbackProbe
    rows <-
      withConn pool $ \connection ->
        query connection "SELECT count(*) FROM conversations WHERE title = 'rollback probe'" ()
    (rows :: [Only Int]) `shouldBe` [Only 0]

  it "keeps nested domain writes inside the outer rollback" $ do
    result <-
      try
        ( withDb pool $ Transaction.withTransaction $ do
            _ <- execute "INSERT INTO conversations(conversation_kind,title) VALUES('group','outer nested probe')" ()
            Transaction.withTransaction $ do
              _ <- execute "INSERT INTO conversations(conversation_kind,title) VALUES('group','inner nested probe')" ()
              pure ()
            liftIO (throwIO RollbackProbe)
        ) ::
        IO (Either RollbackProbe ())
    result `shouldBe` Left RollbackProbe
    rows <- withConn pool $ \connection -> query connection "SELECT count(*) FROM conversations WHERE title LIKE '%nested probe'" ()
    (rows :: [Only Int]) `shouldBe` [Only 0]

  it "can roll back a failed nested operation while retaining the outer transaction" $ do
    withDb pool $ Transaction.withTransaction $ do
      _ <- execute "INSERT INTO conversations(conversation_kind,title) VALUES('group','outer retained probe')" ()
      _ <- EffException.try @RollbackProbe $ Transaction.withTransaction $ do
        _ <- execute "INSERT INTO conversations(conversation_kind,title) VALUES('group','inner rejected probe')" ()
        liftIO (throwIO RollbackProbe)
      pure ()
    rows <- withConn pool $ \connection -> query connection "SELECT title FROM conversations ORDER BY title" ()
    rows `shouldBe` [Only ("outer retained probe" :: String)]
