module Max.MatrixSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Max.IR
import Max.IR.Lower
import Max.Matrix
import Max.Platform.Delivery (loweredText)
import Max.Platform.Types
import Test.Hspec

spec :: Spec
spec = describe "Matrix adapter" $ do
  it "lowers a canonical cross-platform mention to readable @username text" $ do
    let lowered =
          lower matrixTextEnv $
            Body
              [ NMention (MentionIdentity (PrincipalIdentityId 7)) "用户名",
                NText " 在吗，找你"
              ]
    traverse loweredText lowered.chunks `shouldBe` Right ["@用户名 在吗，找你"]

  it "keeps the id-shaped display when no richer label was captured" $ do
    let lowered =
          lower matrixTextEnv $
            Body [NMention (MentionIdentity (PrincipalIdentityId 7)) "1578034713"]
    traverse loweredText lowered.chunks `shouldBe` Right ["@1578034713"]

  it "parses one allowlisted room timeline with reply and mention provenance" $ do
    let value =
          object
            [ "next_batch" .= ("s2" :: String),
              "rooms"
                .= object
                  [ "join"
                      .= object
                        [ "!room:test"
                            .= object
                              [ "timeline"
                                  .= object
                                    [ "limited" .= True,
                                      "prev_batch" .= ("back" :: String),
                                      "events"
                                        .= [ object
                                               [ "event_id" .= ("$event" :: String),
                                                 "sender" .= ("@alice:test" :: String),
                                                 "origin_server_ts" .= (1000 :: Int),
                                                 "type" .= ("m.room.message" :: String),
                                                 "content"
                                                   .= object
                                                     [ "msgtype" .= ("m.text" :: String),
                                                       "body" .= ("hello Max" :: String),
                                                       "formatted_body"
                                                         .= ("<mx-reply><a href=\"https://matrix.to/#/@max:test\">old</a></mx-reply><a href=\"https://matrix.to/#/@max:test\">Max</a> hello" :: String),
                                                       "m.mentions" .= object ["user_ids" .= ["@max:test" :: String]],
                                                       "m.relates_to"
                                                         .= object
                                                           [ "m.in_reply_to"
                                                               .= object ["event_id" .= ("$parent" :: String)]
                                                           ]
                                                     ]
                                               ]
                                           ]
                                    ]
                              ]
                        ]
                  ]
            ]
    page <- parseMatrixSyncPage "!room:test" value `shouldSatisfyRight` const True
    page.nextBatch `shouldBe` "s2"
    page.limited `shouldBe` True
    page.prevBatch `shouldBe` Just "back"
    case page.events of
      [event] -> do
        event.eventId `shouldBe` NativeEventId "$event"
        event.content
          `shouldBe` [NText "hello ", NMention (NativeUserId "@max:test") "Max"]
        event.relations `shouldBe` [ReplyTo (NativeEventId "$parent")]
        event.mentionedUsers `shouldBe` [NativeUserId "@max:test"]
        matrixSelfMentionIsDirect (NativeUserId "@max:test") event `shouldBe` True
      _ -> expectationFailure "expected exactly one event"

  it "does not turn a reply-generated mention of the mirror transport into an @Max trigger" $ do
    let self = NativeUserId "@max:test"
        raw =
          object
            [ "content"
                .= object
                  [ "body" .= ("reply" :: String),
                    "m.mentions" .= object ["user_ids" .= ["@max:test" :: String]],
                    "m.relates_to"
                      .= object
                        [ "m.in_reply_to"
                            .= object ["event_id" .= ("$mirrored-user-message" :: String)]
                        ]
                  ]
            ]
        event =
          MatrixEvent
            (NativeEventId "$reply")
            (NativeUserId "@alice:test")
            (posixSecondsToUTCTime 0)
            EventMessage
            [NText "reply"]
            [ReplyTo (NativeEventId "$mirrored-user-message")]
            [self]
            raw
    matrixSelfMentionIsDirect self event `shouldBe` False

  it "keeps edits, reactions, and redactions as distinct event kinds" $ do
    let event eventId eventType content extra =
          object
            ( [ "event_id" .= eventId,
                "sender" .= ("@alice:test" :: String),
                "origin_server_ts" .= (1000 :: Int),
                "type" .= eventType,
                "content" .= content
              ]
                <> extra
            )
        edit =
          event
            ("$edit" :: String)
            ("m.room.message" :: String)
            ( object
                [ "msgtype" .= ("m.text" :: String),
                  "body" .= ("fixed" :: String),
                  "m.relates_to"
                    .= object
                      [ "rel_type" .= ("m.replace" :: String),
                        "event_id" .= ("$old" :: String)
                      ]
                ]
            )
            []
        reaction =
          event
            ("$reaction" :: String)
            ("m.reaction" :: String)
            ( object
                [ "m.relates_to"
                    .= object
                      [ "rel_type" .= ("m.annotation" :: String),
                        "event_id" .= ("$old" :: String),
                        "key" .= ("👍" :: String)
                      ]
                ]
            )
            []
        redaction =
          event
            ("$redaction" :: String)
            ("m.room.redaction" :: String)
            (object [])
            ["redacts" .= ("$old" :: String)]
        sync =
          object
            [ "next_batch" .= ("s3" :: String),
              "rooms"
                .= object
                  [ "join"
                      .= object
                        [ "!room:test"
                            .= object ["timeline" .= object ["events" .= [edit, reaction, redaction]]]
                        ]
                  ]
            ]
    result <- parseMatrixSyncPage "!room:test" sync `shouldSatisfyRight` const True
    fmap (.eventKind) result.events `shouldBe` [EventEdit, EventReaction, EventRedaction]

  it "never renders an access token through Show" $ do
    let cfg = MatrixConfig "https://matrix.test" "super-secret" "@max:test" "!room:test" (Just 42) 30000
    show cfg `shouldNotContain` "super-secret"

  it "advertises the outbound features implemented by the adapter" $ do
    matrixCapabilities.text `shouldBe` True
    matrixCapabilities.image `shouldBe` TierNative
    matrixCapabilities.reply `shouldBe` TierNative

  it "treats homeserver media size metadata as advisory" $ do
    matrixMediaSizeDrift (Just 145874) 145964 `shouldBe` True
    matrixMediaSizeDrift (Just 145964) 145964 `shouldBe` False
    matrixMediaSizeDrift Nothing 145964 `shouldBe` False

matrixTextEnv :: LowerEnv
matrixTextEnv =
  LowerEnv
    { platform = PlatformMatrix,
      caps = textOnlyCaps,
      attribution = Nothing,
      mentionNative = const Nothing,
      mediaResolve = const Nothing,
      replyTarget = Nothing
    }

shouldSatisfyRight :: (Show e, Show a) => Either e a -> (a -> Bool) -> IO a
shouldSatisfyRight value predicate = case value of
  Left err -> expectationFailure (show err) >> fail "unreachable"
  Right result -> do
    result `shouldSatisfy` predicate
    pure result
