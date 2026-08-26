module Max.IMessageSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString qualified as BS
import Max.IMessage
import Max.IR
import Max.IR.Lower (OutboundCaps (..), Tier (..))
import Max.IR.Prompt (promptText)
import Max.Platform.Types (EventKind (..), NativeEventId (..), NativeUserId (..))
import Test.Hspec

spec :: Spec
spec = describe "iMessage adapter" $ do
  it "uses IMCore only for replies and keeps bridge-validated send GUIDs" $ do
    let replyTarget = Just (NativeEventId "parent-guid")
    iMessageSendTransport Nothing `shouldBe` "applescript"
    iMessageSendTransport replyTarget `shouldBe` "bridge"
    iMessageAuthoritativeSendGuid Nothing (Just "sent-guid")
      `shouldBe` Just (NativeEventId "sent-guid")
    iMessageAuthoritativeSendGuid replyTarget (Just "reply-guid")
      `shouldBe` Just (NativeEventId "reply-guid")

  it "emits native iMessage reply and attachment contracts" $ do
    let cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" [] "Maxwell" Nothing 1000
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
        -- Messages advances reply_to_guid along the conversation, while the
        -- thread originator remains the bubble selected by the user.
        iMessageReplyTarget message `shouldBe` Just "GUID-1"
        fmap (.attachmentId) message.attachments `shouldBe` ["abc123"]
      _ -> expectationFailure "expected one message"

  it "falls back to the inline thread root when no predecessor is available" $ do
    let value =
          object
            [ "messages"
                .= [ object
                       [ "id" .= (42 :: Int),
                         "chat_id" .= (7 :: Int),
                         "guid" .= ("GUID-REPLY" :: String),
                         "sender" .= ("+85212345678" :: String),
                         "is_from_me" .= False,
                         "text" .= ("first inline reply" :: String),
                         "created_at" .= ("2026-08-03T12:00:01Z" :: String),
                         "thread_originator_guid" .= ("GUID-ROOT" :: String)
                       ]
                   ],
              "next_rowid" .= (42 :: Int),
              "has_more" .= False
            ]
    page <- parseIMessagePage value `shouldSatisfyRight` const True
    case page.messages of
      [message] -> iMessageReplyTarget message `shouldBe` Just "GUID-ROOT"
      _ -> expectationFailure "expected one message"

  it "types unnamed QQ images before uploading them to Messages" $ do
    let untyped =
          MediaMeta
            { kind = MImage,
              mime = Nothing,
              sizeBytes = Nothing,
              name = Nothing,
              description = Nothing,
              raw = Nothing
            }
        typed = iMessageUploadMeta untyped (BS.pack [0xff, 0xd8, 0xff, 0xe0])
    typed.mime `shouldBe` Just "image/jpeg"
    iMessageMediaFilename typed `shouldBe` "attachment.jpg"

  it "preserves an explicit attachment name and MIME type" $ do
    let explicit =
          MediaMeta
            { kind = MImage,
              mime = Just "image/png",
              sizeBytes = Nothing,
              name = Just "photo.bin",
              description = Nothing,
              raw = Nothing
            }
        typed = iMessageUploadMeta explicit (BS.pack [0xff, 0xd8, 0xff])
    typed.mime `shouldBe` Just "image/png"
    iMessageMediaFilename typed `shouldBe` "photo.bin"

  it "identifies a transport-account reply shape without making its mention direct" $ do
    let cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" ["hnkhgn@icloud.com"] "Maxwell" (Just 611798505) 1000
        value =
          object
            [ "messages"
                .= [ object
                       [ "id" .= (43 :: Int),
                         "chat_id" .= (7 :: Int),
                         "guid" .= ("GUID-TRANSPORT-REPLY" :: String),
                         "sender" .= ("person@example.com" :: String),
                         "is_from_me" .= False,
                         "text" .= ("@Maxwell" :: String),
                         "created_at" .= ("2026-08-26T04:45:15Z" :: String),
                         "reply_to_guid" .= ("MIRRORED-QQ-GUID" :: String)
                       ]
                   ],
              "next_rowid" .= (43 :: Int),
              "has_more" .= False
            ]
    page <- parseIMessagePage value `shouldSatisfyRight` const True
    case page.messages of
      [message] -> do
        iMessageReplyTarget message `shouldBe` Nothing
        iMessageTransportReplyCandidate cfg message
          `shouldBe` Just (NativeEventId "MIRRORED-QQ-GUID")
        iMessageTextNodesWithTransportReply cfg False message
          `shouldBe` [NMention (NativeUserId "mac-account") "Maxwell"]
        iMessageTextNodesWithTransportReply cfg True message
          `shouldBe` [NText "@Maxwell"]
      _ -> expectationFailure "expected one message"

  it "does not infer a transport reply from an ordinary addressed sentence" $ do
    let cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" [] "Maxwell" (Just 611798505) 1000
        value =
          object
            [ "messages"
                .= [ object
                       [ "id" .= (44 :: Int),
                         "chat_id" .= (7 :: Int),
                         "guid" .= ("GUID-DIRECT" :: String),
                         "sender" .= ("person@example.com" :: String),
                         "text" .= ("@Maxwell hello" :: String),
                         "created_at" .= ("2026-08-26T04:46:00Z" :: String),
                         "reply_to_guid" .= ("ROLLING-PREDECESSOR" :: String)
                       ]
                   ],
              "next_rowid" .= (44 :: Int),
              "has_more" .= False
            ]
    page <- parseIMessagePage value `shouldSatisfyRight` const True
    case page.messages of
      [message] -> iMessageTransportReplyCandidate cfg message `shouldBe` Nothing
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
        cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" ["hnkhgn@icloud.com"] "Maxwell" Nothing 1000
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
    let cfg = IMessageConfig "http://100.64.0.25:8787" "secret-token" "m1pro" "iMessage;+;chat" ["hnkhgn@icloud.com"] "Maxwell" Nothing 1000
    show cfg `shouldNotContain` "secret-token"

  it "binds a confirmed mention to the Apple handle, not the local display name" $ do
    let cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" ["hnkhgn@icloud.com"] "Maxwell" Nothing 1000
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
    let cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" ["1578034713"] "Maxwell" Nothing 1000
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
        promptText (Body nodes) `shouldBe` "👋 @Maxwell hey"
        message.mentionedHandles `shouldBe` ["1578034713"]
      _ -> expectationFailure "expected one mentioned message"

  -- The bridge in production has never sent attributed ranges, only
  -- @mentioned_handles@.  'iMessageIsAddressed' judged those correctly and had
  -- no caller, so the nodes said "plain text" and every @ went unanswered.
  -- These assert the wiring, not the predicate: they read the node list.
  it "recovers a rangeless mention and binds it to the registered account" $ do
    let cfg = IMessageConfig "http://bridge.test" "secret" "mac-account" "iMessage;+;chat" ["hnkhgn@icloud.com"] "Maxwell" Nothing 1000
        page :: Int -> String -> [String] -> String -> Value
        page row guid handles text =
          object
            [ "messages"
                .= [ object
                       [ "id" .= row,
                         "chat_id" .= (7 :: Int),
                         "guid" .= guid,
                         "sender" .= ("person@example.com" :: String),
                         "text" .= text,
                         "mentioned_handles" .= handles,
                         "created_at" .= ("2026-08-19T06:04:06Z" :: String)
                       ]
                   ],
              "next_rowid" .= row,
              "has_more" .= False
            ]
        nodesOf value = do
          parsed <- parseIMessagePage value `shouldSatisfyRight` const True
          case parsed.messages of
            [message] -> pure (iMessageTextNodes cfg message)
            _ -> expectationFailure "expected one message" >> pure []

    -- Messages puts the mention's display name inline; the node replaces it,
    -- and carries 'accountKey' because that is the identity with a principal.
    confirmed <- nodesOf (page 48 "GUID-HANDLE" ["hnkhgn@icloud.com"] "Maxwell 走远了")
    confirmed `shouldBe` [NMention (NativeUserId "mac-account") "Maxwell", NText " 走远了"]

    -- A typed @ carries no metadata at all.  The @ belongs to the mention, so
    -- it must not survive as a stray text node.
    typed <- nodesOf (page 49 "GUID-TYPED" [] "@Maxwell 在吗")
    typed `shouldBe` [NMention (NativeUserId "mac-account") "Maxwell", NText " 在吗"]

    -- Someone else's name in the text is not an address.
    plain <- nodesOf (page 50 "GUID-PLAIN" [] "走远了")
    plain `shouldBe` [NText "走远了"]

  it "advertises bounded outbound attachment delivery" $ do
    iMessageCapabilities.text `shouldBe` True
    iMessageCapabilities.image `shouldBe` TierNative
    iMessageCapabilities.sticker `shouldBe` TierNative
    iMessageCapabilities.video `shouldBe` TierNative
    iMessageCapabilities.audio `shouldBe` TierNative
    iMessageCapabilities.file `shouldBe` TierNative
    iMessageCapabilities.reply `shouldBe` TierText
    iMessageCapabilities.reaction `shouldBe` False
    iMessageCapabilities.edit `shouldBe` False
    iMessageCapabilities.redact `shouldBe` False
    iMessageCapabilities.maxNativeMedia `shouldBe` 8
    (iMessageCapabilitiesFor True).reply `shouldBe` TierNative
    (iMessageCapabilitiesFor False).reply `shouldBe` TierText

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
