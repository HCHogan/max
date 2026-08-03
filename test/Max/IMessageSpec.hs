module Max.IMessageSpec (spec) where

import Data.Aeson (object, (.=))
import Max.IMessage
import Max.Platform.Types (PlatformCapabilities (..))
import Test.Hspec

spec :: Spec
spec = describe "iMessage adapter" $ do
  it "parses authoritative messages.after cursor and stable GUID provenance" $ do
    let value =
          object
            [ "messages"
                .= [ object
                       [ "id" .= (41 :: Int),
                         "chat_id" .= (7 :: Int),
                         "guid" .= ("GUID-41" :: String),
                         "sender" .= ("+85212345678" :: String),
                         "sender_name" .= ("Alice" :: String),
                         "is_from_me" .= False,
                         "text" .= ("@Max hello" :: String),
                         "created_at" .= ("2026-08-03T12:00:00Z" :: String),
                         "reply_to_guid" .= ("GUID-1" :: String),
                          "attachments"
                           .= [ object
                                  [ "attachment_id" .= ("abc123" :: String),
                                    "mime_type" .= ("image/jpeg" :: String),
                                    "byte_size" .= (1234 :: Int),
                                    "transfer_name" .= ("a.jpg" :: String)
                                  ]
                              ]
                       ]
                   ],
              "next_rowid" .= (55 :: Int),
              "has_more" .= True
            ]
    page <- parseIMessagePage value `shouldSatisfyRight` const True
    page.nextRowId `shouldBe` 55
    page.hasMore `shouldBe` True
    case page.messages of
      [message] -> do
        message.guid `shouldBe` "GUID-41"
        message.replyToGuid `shouldBe` Just "GUID-1"
        fmap (.attachmentId) message.attachments `shouldBe` ["abc123"]
      _ -> expectationFailure "expected one message"

  it "parses standalone reactions without coercing them into chat text" $ do
    let value =
          object
            [ "messages"
                .= [ object
                       [ "id" .= (42 :: Int),
                         "chat_id" .= (7 :: Int),
                         "guid" .= ("GUID-R" :: String),
                         "sender" .= ("+85212345678" :: String),
                         "is_from_me" .= False,
                         "text" .= ("" :: String),
                         "created_at" .= ("2026-08-03T12:00:01Z" :: String),
                         "is_reaction" .= True,
                         "reaction_type" .= ("like" :: String),
                         "reacted_to_guid" .= ("GUID-41" :: String)
                       ]
                   ],
              "next_rowid" .= (42 :: Int),
              "has_more" .= False
            ]
    page <- parseIMessagePage value `shouldSatisfyRight` const True
    case page.messages of
      [message] -> do
        message.isReaction `shouldBe` True
        message.reactionKey `shouldBe` Just "like"
        message.reactedToGuid `shouldBe` Just "GUID-41"
      _ -> expectationFailure "expected one reaction"

  it "parses the authoritative send status used to release uncertain sends" $ do
    parseIMessageSendState
      (object ["ok" .= True, "guid" .= ("GUID-O" :: String), "send_state" .= ("delivered" :: String)])
      `shouldBe` Right IMessageSendDelivered
    parseIMessageSendState
      (object ["ok" .= True, "send_state" .= ("failed" :: String)])
      `shouldBe` Right IMessageSendFailed

  it "redacts the bridge token from Show" $ do
    let cfg = IMessageConfig "http://100.64.0.25:8787" "secret-token" "m1pro" "iMessage;+;chat" "Max" 1000
    show cfg `shouldNotContain` "secret-token"

  it "advertises bounded outbound attachment delivery" $ do
    iMessageCapabilities.canSendText `shouldBe` True
    iMessageCapabilities.canSendMedia `shouldBe` True
    iMessageCapabilities.canReply `shouldBe` False

shouldSatisfyRight :: (Show e, Show a) => Either e a -> (a -> Bool) -> IO a
shouldSatisfyRight value predicate = case value of
  Left err -> expectationFailure (show err) >> fail "unreachable"
  Right result -> do
    result `shouldSatisfy` predicate
    pure result
