module Max.IMessageSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Max.IMessage
import Max.IR
import Max.IR.Lower (OutboundCaps (..), Tier (..))
import Max.IR.Prompt (promptText)
import Max.Platform.Types (EventKind (..), NativeEventId (..), NativeUserId (..), Platform (..))
import Test.Hspec

spec :: Spec
spec = describe "iMessage adapter" $ do
  it "uses IMCore only for replies and waits for their authoritative echo GUID" $ do
    let replyTarget = Just (NativeEventId "parent-guid")
    iMessageSendTransport Nothing `shouldBe` "applescript"
    iMessageSendTransport replyTarget `shouldBe` "bridge"
    iMessageAuthoritativeSendGuid Nothing (Just "sent-guid")
      `shouldBe` Just (NativeEventId "sent-guid")
    iMessageAuthoritativeSendGuid replyTarget (Just "stale-guid") `shouldBe` Nothing

  it "emits native iMessage reply and attachment contracts" $ do
    let cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" [] "Maxwell" 1000
        target = Just (NativeEventId "parent-guid")
    iMessageSendParams cfg target "caption" (Just "upload:attachment-id")
      `shouldBe` object
        [ "chat_guid" .= ("iMessage;+;chat" :: String),
          "text" .= ("caption" :: String),
          "service" .= ("auto" :: String),
          "transport" .= ("bridge" :: String),
          "file" .= ("upload:attachment-id" :: String),
          "reply_to" .= ("parent-guid" :: String)
        ]

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
                         "reply_to_guid" .= ("PREVIOUS-GUID" :: String),
                         "thread_originator_guid" .= ("GUID-1" :: String),
                         "mentioned_handles" .= (["hnkhgn@icloud.com"] :: [String]),
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
        message.replyToGuid `shouldBe` Just "PREVIOUS-GUID"
        message.threadOriginatorGuid `shouldBe` Just "GUID-1"
        message.mentionedHandles `shouldBe` ["hnkhgn@icloud.com"]
        iMessageReplyTarget message `shouldBe` Just "GUID-1"
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

  it "does not promote the macOS predecessor chain into an inline reply" $ do
    let value =
          object
            [ "messages"
                .= [ object
                       [ "id" .= (44 :: Int),
                         "chat_id" .= (7 :: Int),
                         "guid" .= ("GUID-TOP-LEVEL" :: String),
                         "sender" .= ("+85212345678" :: String),
                         "is_from_me" .= False,
                         "text" .= ("ordinary ambient message" :: String),
                         "created_at" .= ("2026-08-03T12:00:03Z" :: String),
                         "reply_to_guid" .= ("PREVIOUS-MESSAGE" :: String)
                       ]
                   ],
              "next_rowid" .= (44 :: Int),
              "has_more" .= False
            ]
    page <- parseIMessagePage value `shouldSatisfyRight` const True
    case page.messages of
      [message] -> do
        message.replyToGuid `shouldBe` Just "PREVIOUS-MESSAGE"
        message.threadOriginatorGuid `shouldBe` Nothing
        iMessageReplyTarget message `shouldBe` Nothing
      _ -> expectationFailure "expected one top-level message"

  it "keeps senderless Messages rows as non-dispatching system provenance" $ do
    let value =
          object
            [ "messages"
                .= [ object
                       [ "id" .= (43 :: Int),
                         "chat_id" .= (7 :: Int),
                         "guid" .= ("GUID-SYSTEM" :: String),
                         "sender" .= ("" :: String),
                         "is_from_me" .= False,
                         "text" .= ("" :: String),
                         "created_at" .= ("2026-08-03T12:00:02Z" :: String)
                       ]
                   ],
              "next_rowid" .= (43 :: Int),
              "has_more" .= False
            ]
        cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" ["hnkhgn@icloud.com"] "Maxwell" 1000
    page <- parseIMessagePage value `shouldSatisfyRight` const True
    case page.messages of
      [message] -> do
        iMessageEventKind message `shouldBe` EventMembership
        iMessageIngressIdentity cfg message
          `shouldBe` (NativeUserId "system", Just "iMessage system")
      _ -> expectationFailure "expected one system event"

  it "parses the authoritative send status used to release uncertain sends" $ do
    parseIMessageSendState
      (object ["ok" .= True, "guid" .= ("GUID-O" :: String), "send_state" .= ("delivered" :: String)])
      `shouldBe` Right IMessageSendDelivered
    parseIMessageSendState
      (object ["ok" .= True, "send_state" .= ("failed" :: String)])
      `shouldBe` Right IMessageSendFailed

  it "redacts the bridge token from Show" $ do
    let cfg = IMessageConfig "http://100.64.0.25:8787" "secret-token" "m1pro" "iMessage;+;chat" ["hnkhgn@icloud.com"] "Maxwell" 1000
    show cfg `shouldNotContain` "secret-token"

  it "binds a confirmed mention to the Apple handle, not the local display name" $ do
    let cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" ["hnkhgn@icloud.com"] "Maxwell" 1000
        confirmed = mentionPage 45 "GUID-MENTION" (["hnkhgn@icloud.com"] :: [String])
        plain = mentionPage 46 "GUID-PLAIN" ([] :: [String])
        mentionPage :: Int -> String -> [String] -> Value
        mentionPage row guid handles =
          object
            [ "messages"
                .= [ object
                       [ "id" .= row,
                         "chat_id" .= (7 :: Int),
                         "guid" .= guid,
                         "sender" .= ("person@example.com" :: String),
                         "is_from_me" .= False,
                         "text" .= ("Maxwell hey" :: String),
                         "mentioned_handles" .= handles,
                         "created_at" .= ("2026-08-03T12:00:04Z" :: String)
                       ]
                   ],
              "next_rowid" .= row,
              "has_more" .= False
            ]
    confirmedPage <- parseIMessagePage confirmed `shouldSatisfyRight` const True
    plainPage <- parseIMessagePage plain `shouldSatisfyRight` const True
    case (confirmedPage.messages, plainPage.messages) of
      ([confirmedMessage], [plainMessage]) -> do
        iMessageIsAddressed cfg confirmedMessage `shouldBe` True
        iMessageIsAddressed cfg plainMessage `shouldBe` False
      _ -> expectationFailure "expected one confirmed and one plain message"

  it "maps attributed UTF-16 ranges to semantic mentions without QQ-id guessing" $ do
    let cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" ["1578034713"] "Maxwell" 1000
        value =
          object
            [ "messages"
                .= [ object
                       [ "id" .= (47 :: Int),
                         "chat_id" .= (7 :: Int),
                         "guid" .= ("GUID-SPAN" :: String),
                         "sender" .= ("person@example.com" :: String),
                         "text" .= ("👋 Maxwell hey" :: String),
                         "mentions"
                           .= [ object
                                  [ "handle" .= ("1578034713" :: String),
                                    "display" .= ("Maxwell" :: String),
                                    "utf16_location" .= (3 :: Int),
                                    "utf16_length" .= (7 :: Int)
                                  ]
                              ],
                         "created_at" .= ("2026-08-03T12:00:05Z" :: String)
                       ]
                   ],
              "next_rowid" .= (47 :: Int),
              "has_more" .= False
            ]
    page <- parseIMessagePage value `shouldSatisfyRight` const True
    case page.messages of
      [message] -> do
        let nodes = iMessageTextNodes cfg message
        nodes
          `shouldBe` [NText "👋 ", NMention (NativeUserId "1578034713") "Maxwell", NText " hey"]
        promptText PlatformIMessage (Body nodes) `shouldBe` "👋 @Maxwell hey"
        message.mentionedHandles `shouldBe` ["1578034713"]
      _ -> expectationFailure "expected one mentioned message"

  it "advertises bounded outbound attachment delivery" $ do
    iMessageCapabilities.text `shouldBe` True
    iMessageCapabilities.image `shouldBe` TierNative
    iMessageCapabilities.reply `shouldBe` TierText

  it "parses a live IMCore reply capability and defaults old bridges safely" $ do
    parseIMessageBridgeHealth
      ( object
          [ "source_fingerprint" .= ("device:inode:birth" :: String),
            "capabilities" .= object ["reply" .= True]
          ]
      )
      `shouldBe` Right (IMessageBridgeHealth "device:inode:birth" True)
    parseIMessageBridgeHealth
      (object ["source_fingerprint" .= ("old-bridge" :: String)])
      `shouldBe` Right (IMessageBridgeHealth "old-bridge" False)

shouldSatisfyRight :: (Show e, Show a) => Either e a -> (a -> Bool) -> IO a
shouldSatisfyRight value predicate = case value of
  Left err -> expectationFailure (show err) >> fail "unreachable"
  Right result -> do
    result `shouldSatisfy` predicate
    pure result
