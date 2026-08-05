module Max.DB.FilesSpec (spec) where

import Data.Int (Int64)
import Helpers (insertMessageWithCanonicalId, testTime, truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.Files (FileRecord (..), fetchByFileIdInScope, fetchFilesForMessageInScope, insertSeen)
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

    it "does not resolve another conversation file_id" $ do
      seedMessages
      withDb pool $ insertSeen "file-b" groupB (Just 9002) sender "secret.txt" Nothing
      fromA <- withDb pool $ fetchByFileIdInScope scopeA "file-b"
      fromB <- withDb pool $ fetchByFileIdInScope scopeB "file-b"
      fromA `shouldSatisfy` isNothing
      fmap (.frFileName) fromB `shouldBe` Just "secret.txt"

    it "confines message attachment lookup even when message ids are supplied directly" $ do
      seedMessages
      withDb pool $ insertSeen "file-a" groupA (Just 9001) sender "visible.txt" Nothing
      withDb pool $ insertSeen "file-b" groupB (Just 9002) sender "secret.txt" Nothing
      visible <- withDb pool $ fetchFilesForMessageInScope scopeA 9001
      hidden <- withDb pool $ fetchFilesForMessageInScope scopeA 9002
      map (.frFileId) visible `shouldBe` ["file-a"]
      hidden `shouldSatisfy` null

-- Keep this local rather than importing Data.Maybe for one predicate.
isNothing :: Maybe a -> Bool
isNothing Nothing = True
isNothing Just {} = False
