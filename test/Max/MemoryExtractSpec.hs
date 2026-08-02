module Max.MemoryExtractSpec (spec) where

import Data.Time (addUTCTime, getCurrentTime)
import Max.MemoryExtract
  ( ExtractOp (..),
    memxPendingDeadline,
    newMemxScheduler,
    parseOps,
    retryMemxAfterFailureAt,
  )
import Max.MemoryStore (MemoryId (..), MemoryVersion (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "failure scheduling" $ do
    it "re-arms a failed group after one minute" $ do
      sched <- newMemxScheduler
      now <- getCurrentTime
      retryMemxAfterFailureAt sched (GroupId 42) now
      memxPendingDeadline sched (GroupId 42)
        `shouldReturn` Just (addUTCTime 60 now)

    it "does not overwrite a newer schedule installed meanwhile" $ do
      sched <- newMemxScheduler
      now <- getCurrentTime
      retryMemxAfterFailureAt sched (GroupId 42) now
      retryMemxAfterFailureAt sched (GroupId 42) (addUTCTime 300 now)
      memxPendingDeadline sched (GroupId 42)
        `shouldReturn` Just (addUTCTime 60 now)

  describe "parseOps" $ do
    it "parses a plain JSON array" $
      parseOps "[{\"action\":\"add\",\"scope\":\"user\",\"user_id\":123,\"content\":\"喜欢 Haskell\"}]"
        `shouldBe` Right [OpAdd "user" (Just 123) "喜欢 Haskell"]

    it "parses update and delete" $
      parseOps "[{\"action\":\"update\",\"id\":5,\"version\":2,\"content\":\"新内容\"},{\"action\":\"delete\",\"id\":7,\"version\":4}]"
        `shouldBe` Right [OpUpdate (MemoryId 5) (MemoryVersion 2) "新内容", OpDelete (MemoryId 7) (MemoryVersion 4)]

    it "accepts an empty array" $
      parseOps "[]" `shouldBe` Right []

    it "strips markdown code fences" $
      parseOps "```json\n[{\"action\":\"delete\",\"id\":3,\"version\":1}]\n```"
        `shouldBe` Right [OpDelete (MemoryId 3) (MemoryVersion 1)]

    it "tolerates prose around the array" $
      parseOps "好的，以下是操作：\n[{\"action\":\"delete\",\"id\":3,\"version\":1}] 完毕"
        `shouldBe` Right [OpDelete (MemoryId 3) (MemoryVersion 1)]

    it "add without user_id defaults later (parses as Nothing)" $
      parseOps "[{\"action\":\"add\",\"scope\":\"group\",\"content\":\"c\"}]"
        `shouldBe` Right [OpAdd "group" Nothing "c"]

    it "rejects unknown actions" $
      parseOps "[{\"action\":\"merge\",\"id\":1}]" `shouldSatisfy` isLeft
  where
    isLeft = either (const True) (const False)
