module Max.DB.FilesSpec (spec) where

import Data.Int (Int64)
import Helpers (truncateAll, withDb)
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

    it "does not resolve another conversation file_id" $ do
      withDb pool $ insertSeen "file-b" groupB (Just 9002) sender "secret.txt" Nothing
      fromA <- withDb pool $ fetchByFileIdInScope scopeA "file-b"
      fromB <- withDb pool $ fetchByFileIdInScope scopeB "file-b"
      fromA `shouldSatisfy` isNothing
      fmap (.frFileName) fromB `shouldBe` Just "secret.txt"

    it "confines message attachment lookup even when message ids are supplied directly" $ do
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
