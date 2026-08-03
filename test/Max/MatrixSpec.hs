module Max.MatrixSpec (spec) where

import Data.Aeson (object, (.=))
import Max.Matrix
import Max.Platform.Types
import Test.Hspec

spec :: Spec
spec = describe "Matrix adapter" $ do
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
        event.content `shouldBe` [ContentText "hello Max"]
        event.relations `shouldBe` [ReplyTo (NativeEventId "$parent")]
        event.mentionedUsers `shouldBe` [NativeUserId "@max:test"]
      _ -> expectationFailure "expected exactly one event"

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
    matrixCapabilities.canSendText `shouldBe` True
    matrixCapabilities.canSendMedia `shouldBe` True
    matrixCapabilities.canReply `shouldBe` True

shouldSatisfyRight :: (Show e, Show a) => Either e a -> (a -> Bool) -> IO a
shouldSatisfyRight value predicate = case value of
  Left err -> expectationFailure (show err) >> fail "unreachable"
  Right result -> do
    result `shouldSatisfy` predicate
    pure result
