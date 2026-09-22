module Max.DB.FilesSpec (spec) where

import Control.Monad (void)
import Data.Int (Int64)
import Effectful.PostgreSQL (execute)
import Helpers (insertMessageWithCanonicalId, testTime, truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.Files (FileRecord (..), fetchFilesForMessageInScope, insertSeen, listConversationFilesInScope)
import OneBot.Types (GroupId (..))
import Test.Hspec

groupA, groupB, sender :: Int64
groupA = 100
groupB = 200
sender = 3001

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "Max.DB.Files conversation isolation" $ do
    let scopeA = conversationScopeFor (GroupId groupA)
        scopeB = conversationScopeFor (GroupId groupB)
        -- group_files carries a canonical foreign key since ADR 004, so the
        -- messages these files hang off have to exist.
        seedMessages = do
          insertMessageWithCanonicalId pool 9001 groupA sender 1000 testTime Nothing "visible"
          insertMessageWithCanonicalId pool 9002 groupB sender 1000 testTime Nothing "secret"

    it "lists a conversation's files by message, each message's in receipt order" $ do
      seedMessages
      insertMessageWithCanonicalId pool 9003 groupA sender 1000 testTime Nothing "later"
      withDb pool $ insertSeen "file-a1" groupA (Just 9001) sender "old.txt" Nothing
      withDb pool $ insertSeen "file-a3y" groupA (Just 9003) sender "second.txt" Nothing
      withDb pool $ insertSeen "file-a3x" groupA (Just 9003) sender "first.txt" Nothing
      withDb pool $ insertSeen "file-b" groupB (Just 9002) sender "secret.txt" Nothing
      -- Messages in order; one message's files in receipt order.
      void . withDb pool $ execute "UPDATE group_files SET received_at = now() - interval '1 hour' WHERE file_id = 'file-a1'" ()
      void . withDb pool $ execute "UPDATE group_files SET received_at = now() - interval '1 minute' WHERE file_id = 'file-a3y'" ()
      files <- withDb pool $ listConversationFilesInScope scopeA
      map (.frFileId) files `shouldBe` ["file-a1", "file-a3y", "file-a3x"]
      foreign' <- withDb pool $ listConversationFilesInScope scopeB
      map (.frFileId) foreign' `shouldBe` ["file-b"]

    it "confines message attachment lookup even when message ids are supplied directly" $ do
      seedMessages
      withDb pool $ insertSeen "file-a" groupA (Just 9001) sender "visible.txt" Nothing
      withDb pool $ insertSeen "file-b" groupB (Just 9002) sender "secret.txt" Nothing
      visible <- withDb pool $ fetchFilesForMessageInScope scopeA 9001
      hidden <- withDb pool $ fetchFilesForMessageInScope scopeA 9002
      map (.frFileId) visible `shouldBe` ["file-a"]
      hidden `shouldSatisfy` null
