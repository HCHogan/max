module Max.Effects.OutboundSpec (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Effectful (liftIO, runEff)
import Max.MessageKind (MessageKind (KindChat))
import Max.Effects.Outbound
  ( OutboundDeliveryScope (..),
    OutboundRequest (..),
    SendOutcome (..),
    runOutboundWith,
    sendRecorded,
    wasDelivered,
  )
import Max.IR
import Max.Platform.Types (NativeUserId (..))
import OneBot.Types (GroupId (..), MessageId (..))
import Test.Hspec

request :: OutboundRequest
request =
  OutboundRequest
    { orKind = KindChat,
      orGroupId = GroupId 7777,
      orBody = Body [NText "surface"],
      orReplyTo = Nothing,
      orDeliveryScope = DeliverConversation
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

  it "carries semantic IR and keeps reply outside the content body" $ do
    let req =
          request
            { orBody =
                Body
                  [ NMention (NativeUserId "1578034713") "用户名",
                    NText " 在吗，找你"
                  ],
              orReplyTo = Just (MessageId 99)
            }
    req.orBody
      `shouldBe` Body [NMention (NativeUserId "1578034713") "用户名", NText " 在吗，找你"]
    req.orReplyTo `shouldBe` Just (MessageId 99)
