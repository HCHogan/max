module Max.Effects.OutboundSpec (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Effectful (liftIO, runEff)
import Max.DB.Message (MessageKind (KindChat))
import Max.Effects.Outbound
  ( OutboundRequest (..),
    OutboundDeliveryScope (..),
    SendOutcome (..),
    runOutboundWith,
    sendRecorded,
    wasDelivered,
  )
import OneBot.Segment (Segment (SegText))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

request :: OutboundRequest
request =
  OutboundRequest
    { orKind = KindChat,
      orGroupId = GroupId 7777,
      orSelfId = UserId 1000,
      orRenderedText = Just "normalised",
      orSegments = [SegText "surface"],
      orDeliveryScope = DeliverConversation,
      orTimeoutMs = 30000
    }

spec :: Spec
spec = describe "Outbound" $ do
  it "can be interpreted in memory without a platform or database" $ do
    seen <- newIORef Nothing
    let receipt = SentRecorded (MessageId 42)
    actual <-
      runEff
        . runOutboundWith
          (\req -> liftIO (writeIORef seen (Just req)) >> pure receipt)
        $ sendRecorded request
    actual `shouldBe` receipt
    readIORef seen `shouldReturn` Just request

  it "does not invite a duplicate retry after delivery without persistence" $ do
    wasDelivered (SendFailed "offline") `shouldBe` False
    wasDelivered (SentUnrecorded Nothing "missing message id") `shouldBe` True
    wasDelivered (SentUnrecorded (Just (MessageId 42)) "db unavailable") `shouldBe` True
    wasDelivered (SentRecorded (MessageId 42)) `shouldBe` True
