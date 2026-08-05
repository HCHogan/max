module Max.MatrixSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Foldable (for_)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
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

  -- A client that sends markdown in the plain body writes the pill as
  -- [label](https://matrix.to/#/@user).  Matching only the label left the
  -- brackets and the URL in the transcript as text.
  it "consumes a markdown-wrapped pill instead of leaving its link debris" $ do
    let value =
          syncPage
            [ ( "[@max:test](https://matrix.to/#/@max:test) help" :: Text,
                "<a href=\"https://matrix.to/#/@max:test\">@max:test</a> help" :: Text
              )
            ]
    page <- parseMatrixSyncPage "!room:test" value `shouldSatisfyRight` const True
    case page.events of
      [event] ->
        event.content
          `shouldBe` [NMention (NativeUserId "@max:test") "@max:test", NText " help"]
      _ -> expectationFailure "expected exactly one event"

  it "renders an mxid mention with one @, not two" $
    plainText (Body [NMention (MentionIdentity (PrincipalIdentityId 7)) "@max:test", NText " help"])
      `shouldBe` "@max:test help"

  -- The mxid is the only identifier Matrix has; the readable name lives in
  -- per-room member state.  Ignoring it left every Matrix speaker addressed
  -- by id in the transcript.
  it "learns member display names and keeps the events themselves out of the ledger" $ do
    let member user display membership =
          object
            [ "type" .= ("m.room.member" :: Text),
              "state_key" .= (user :: Text),
              "sender" .= user,
              "event_id" .= ("$member-" <> user),
              "origin_server_ts" .= (900 :: Int),
              "content" .= object ["membership" .= (membership :: Text), "displayname" .= (display :: Text)]
            ]
        value =
          object
            [ "next_batch" .= ("s2" :: Text),
              "rooms"
                .= object
                  [ "join"
                      .= object
                        [ "!room:test"
                            .= object
                              [ "state" .= object ["events" .= [member "@hank:test" "hank" "join"]],
                                "timeline"
                                  .= object
                                    [ "events"
                                        .= [ member "@alice:test" "Alice" "join",
                                             member "@ghost:test" "Ghost" "leave"
                                           ]
                                    ]
                              ]
                        ]
                  ]
            ]
    page <- parseMatrixSyncPage "!room:test" value `shouldSatisfyRight` const True
    page.memberNames
      `shouldBe` Map.fromList [("@hank:test", "hank"), ("@alice:test", "Alice")]
    page.events `shouldBe` []

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
                  "body" .= ("* stale fallback" :: String),
                  "m.new_content"
                    .= object
                      [ "msgtype" .= ("m.text" :: String),
                        "body" .= ("fixed Alice" :: String),
                        "formatted_body"
                          .= ("fixed <a href=\"https://matrix.to/#/@alice:test\">Alice</a>" :: String),
                        "m.mentions" .= object ["user_ids" .= ["@alice:test" :: String]]
                      ],
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
    case result.events of
      editEvent : _ -> do
        editEvent.content
          `shouldBe` [NText "fixed ", NMention (NativeUserId "@alice:test") "Alice"]
        editEvent.mentionedUsers `shouldBe` [NativeUserId "@alice:test"]
      _ -> expectationFailure "expected edit event"

  it "never renders an access token through Show" $ do
    let cfg = MatrixConfig "https://matrix.test" "super-secret" "@max:test" "!room:test" (Just 42) 30000
    show cfg `shouldNotContain` "super-secret"

  it "advertises the outbound features implemented by the adapter" $ do
    matrixCapabilities.text `shouldBe` True
    matrixCapabilities.mention `shouldBe` TierNative
    matrixCapabilities.reply `shouldBe` TierNative
    matrixCapabilities.image `shouldBe` TierNative
    matrixCapabilities.sticker `shouldBe` TierNative
    matrixCapabilities.video `shouldBe` TierNative
    matrixCapabilities.audio `shouldBe` TierNative
    matrixCapabilities.file `shouldBe` TierNative
    matrixCapabilities.reaction `shouldBe` True
    matrixCapabilities.edit `shouldBe` True
    matrixCapabilities.redact `shouldBe` True
    matrixCapabilities.maxNativeMedia `shouldBe` 1

  it "emits native Matrix mention, reply, and media contracts" $ do
    let target = Just (NativeEventId "$parent")
        mentionChunk = [NMention (NativeUserId "@alice:test") "Alice", NText " hi"]
        mediaMeta =
          MediaMeta
            { kind = MImage,
              mime = Just "image/png",
              sizeBytes = Just 12,
              name = Just "cat.png",
              description = Just "cat",
              raw = Nothing
            }
    matrixTextPayload target mentionChunk "@Alice hi"
      `shouldBe` object
        [ "msgtype" .= ("m.text" :: String),
          "body" .= ("@Alice hi" :: String),
          "m.relates_to" .= object ["m.in_reply_to" .= object ["event_id" .= ("$parent" :: String)]],
          "m.mentions" .= object ["user_ids" .= ["@alice:test" :: String]]
        ]
    matrixMediaPayload Nothing [] "cat" mediaMeta "mxc://test/cat" (Just 12)
      `shouldBe` object
        [ "msgtype" .= ("m.image" :: String),
          "body" .= ("cat" :: String),
          "filename" .= (Just "cat.png" :: Maybe String),
          "url" .= ("mxc://test/cat" :: String),
          "info"
            .= object
              [ "mimetype" .= (Just "image/png" :: Maybe String),
                "size" .= (Just 12 :: Maybe Int)
              ]
        ]

  it "maps every advertised Matrix media kind to a native event contract" $ do
    let cases :: [(MediaKind, Text, Text)]
        cases =
          [ (MImage, "image/png", "m.image"),
            (MSticker, "image/webp", "m.image"),
            (MVideo, "video/mp4", "m.video"),
            (MAudio, "audio/ogg", "m.audio"),
            (MFile, "application/pdf", "m.file")
          ]
    for_ cases $ \(kind, mime, msgtype) -> do
      let meta = MediaMeta kind (Just mime) (Just 7) (Just "asset") Nothing Nothing
      matrixMediaPayload Nothing [] "asset" meta "mxc://test/asset" (Just 7)
        `shouldBe` object
          [ "msgtype" .= msgtype,
            "body" .= ("asset" :: String),
            "filename" .= (Just "asset" :: Maybe String),
            "url" .= ("mxc://test/asset" :: String),
            "info"
              .= object
                [ "mimetype" .= Just mime,
                  "size" .= (Just 7 :: Maybe Int)
                ]
          ]

  it "emits native Matrix edit and reaction contracts from lowered content" $ do
    let content = object ["msgtype" .= ("m.text" :: String), "body" .= ("fixed" :: String)]
    matrixEditPayload (NativeEventId "$old") content
      `shouldBe` object
        [ "msgtype" .= ("m.text" :: String),
          "body" .= ("* fixed" :: String),
          "m.new_content" .= content,
          "m.relates_to"
            .= object
              [ "rel_type" .= ("m.replace" :: String),
                "event_id" .= ("$old" :: String)
              ]
        ]
    matrixReactionPayload (NativeEventId "$old") "👍"
      `shouldBe` object
        [ "m.relates_to"
            .= object
              [ "rel_type" .= ("m.annotation" :: String),
                "event_id" .= ("$old" :: String),
                "key" .= ("👍" :: String)
              ]
        ]
    matrixRedactionPath "!room:test" "delivery:42" "redact" (NativeEventId "$old")
      `shouldBe` "/_matrix/client/v3/rooms/%21room%3Atest/redact/%24old/delivery%3A42-redact"

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

-- | One joined room, one @m.text@ event per (plain body, formatted body)
-- pair, with @m.mentions@ naming the bot.
syncPage :: [(Text, Text)] -> Value
syncPage bodies =
  object
    [ "next_batch" .= ("s2" :: Text),
      "rooms"
        .= object
          [ "join"
              .= object
                [ "!room:test"
                    .= object
                      [ "timeline" .= object ["events" .= zipWith event [0 :: Int ..] bodies]
                      ]
                ]
          ]
    ]
  where
    event index (body, formatted) =
      object
        [ "event_id" .= ("$event" <> T.pack (show index)),
          "sender" .= ("@alice:test" :: Text),
          "origin_server_ts" .= (1000 :: Int),
          "type" .= ("m.room.message" :: Text),
          "content"
            .= object
              [ "msgtype" .= ("m.text" :: Text),
                "body" .= body,
                "formatted_body" .= formatted,
                "m.mentions" .= object ["user_ids" .= (["@max:test"] :: [Text])]
              ]
        ]
