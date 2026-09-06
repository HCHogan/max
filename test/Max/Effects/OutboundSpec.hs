module Max.Effects.OutboundSpec (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Effectful (liftIO, runEff)
import Max.Effects.Outbound
  ( OutboundDeliveryScope (..),
    OutboundRequest (..),
    PublicationResult (..),
    runOutboundWith,
    sendRecorded,
    wasPublished,
  )
import Max.IR
import Max.MessageKind (MessageKind (KindChat))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalIdentityId (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

request :: OutboundRequest
request =
  OutboundRequest
    { orKind = KindChat,
      orGroupId = GroupId 7777,
      orBody = Body [NText "surface"],
      orReplyTo = Nothing,
      orDeliveryScope = DeliverConversation,
      orTurnOutput = Nothing,
      orMonitorFireId = Nothing
    }

spec :: Spec
spec = describe "Outbound" $ do
  it "can be interpreted in memory without a platform or database" $ do
    seen <- newIORef Nothing
    let receipt = Published (CanonicalMessageId 42)
    actual <-
      runEff
        . runOutboundWith
          (\req -> liftIO (writeIORef seen (Just req)) >> pure receipt)
        $ sendRecorded request
    actual `shouldBe` receipt
    readIORef seen `shouldReturn` Just request

  it "acknowledges only canonical publication" $ do
    wasPublished (PublicationFailed "offline") `shouldBe` False
    wasPublished (Published (CanonicalMessageId 42)) `shouldBe` True

  it "carries semantic IR and keeps reply outside the content body" $ do
    let req =
          request
            { orBody =
                Body
                  [ NMention (MentionIdentity (PrincipalIdentityId 12)) "用户名",
                    NText " 在吗，找你"
                  ],
              orReplyTo = Just (CanonicalMessageId 99)
            }
    req.orBody
      `shouldBe` Body [NMention (MentionIdentity (PrincipalIdentityId 12)) "用户名", NText " 在吗，找你"]
    req.orReplyTo `shouldBe` Just (CanonicalMessageId 99)
