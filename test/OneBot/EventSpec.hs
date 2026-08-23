module OneBot.EventSpec (spec) where

import Data.Aeson (ToJSON, Value, object, (.=))
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import OneBot.Event (EmojiLike (..), Event (..), GroupMessage (..), HistoricalMessage (..), MessageNotice (..), NoticeKind (..), PokeEvent (..), Sender (..), parseEvent, parseHistoryMessages, selectHistoryBefore)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)
import Test.Hspec

spec :: Spec
spec = do
  describe "parseEvent" $ do
    it "parses an incoming friend request" $
      case parseEvent
        ( object
            [ "post_type" .= ("request" :: Text),
              "request_type" .= ("friend" :: Text),
              "flag" .= ("fl4g" :: Text),
              "user_id" .= (2001 :: Int),
              "comment" .= ("hi" :: Text)
            ]
        ) of
        Right (EvFriendRequest flag uid) -> do
          flag `shouldBe` "fl4g"
          uid `shouldBe` UserId 2001
        other -> expectationFailure ("expected EvFriendRequest, got: " <> show other)

    it "parses a group message with its real group id" $
      case parseEvent (msgEvent "group" ["group_id" .= (7777 :: Int)]) of
        Right (EvGroupMessage "qq" _ gm) -> do
          gm.groupId `shouldBe` GroupId 7777
          gm.userId `shouldBe` UserId 2001
        other -> expectationFailure ("expected EvGroupMessage, got: " <> show other)

    it "parses a private message onto the pseudo group id -user_id" $
      case parseEvent (msgEvent "private" []) of
        Right (EvGroupMessage "qq" _ gm) -> do
          gm.groupId `shouldBe` GroupId (-2001)
          gm.userId `shouldBe` UserId 2001
        other -> expectationFailure ("expected EvGroupMessage, got: " <> show other)

    it "does not confuse a foreign synthetic group with a QQ private chat" $ do
      isPrivateChat (GroupId (-2001)) `shouldBe` True
      isPrivateChat (GroupId (-1000000000015)) `shouldBe` False

    it "parses a group poke notice" $
      case parseEvent (pokeEvent ["group_id" .= (7777 :: Int)]) of
        Right (EvPoke pk) -> do
          pk.pkGroupId `shouldBe` GroupId 7777
          pk.pkUserId `shouldBe` UserId 2001
          pk.pkTargetId `shouldBe` UserId 1000
          pk.pkSelfId `shouldBe` UserId 1000
        other -> expectationFailure ("expected EvPoke, got: " <> show other)

    it "parses a friend poke onto the pseudo group id -user_id" $
      case parseEvent (pokeEvent []) of
        Right (EvPoke pk) -> do
          pk.pkGroupId `shouldBe` GroupId (-2001)
          pk.pkUserId `shouldBe` UserId 2001
        other -> expectationFailure ("expected EvPoke, got: " <> show other)

    it "leaves other notify notices as EvRaw" $
      case parseEvent
        ( object
            [ "post_type" .= ("notice" :: Text),
              "notice_type" .= ("notify" :: Text),
              "sub_type" .= ("lucky_king" :: Text)
            ]
        ) of
        Right (EvRaw _) -> pure ()
        other -> expectationFailure ("expected EvRaw, got: " <> show other)

    it "parses group recalls as message meta-events" $
      case parseEvent
        ( object
            [ "post_type" .= ("notice" :: Text),
              "notice_type" .= ("group_recall" :: Text),
              "self_id" .= (1000 :: Int),
              "group_id" .= (7777 :: Int),
              "user_id" .= (2001 :: Int),
              "operator_id" .= (3001 :: Int),
              "message_id" .= (9000 :: Int)
            ]
        ) of
        Right (EvMessageNotice _ notice) | NoticeRecalled <- notice.mnKind -> do
          notice.mnGroupId `shouldBe` GroupId 7777
          notice.mnActorId `shouldBe` UserId 3001
          notice.mnTargetMessageId `shouldBe` MessageId 9000
        other -> expectationFailure ("expected a recall notice, got: " <> show other)

    it "parses reaction polarity and emoji ids" $
      case parseEvent
        ( object
            [ "post_type" .= ("notice" :: Text),
              "notice_type" .= ("group_msg_emoji_like" :: Text),
              "self_id" .= (1000 :: Int),
              "group_id" .= (7777 :: Int),
              "user_id" .= (2001 :: Int),
              "message_id" .= (9000 :: Int),
              "likes" .= [object ["emoji_id" .= ("212" :: Text), "count" .= (0 :: Int)]],
              "is_add" .= False
            ]
        ) of
        Right (EvMessageNotice _ notice) | NoticeReacted likes added <- notice.mnKind -> do
          likes `shouldBe` [EmojiLike "212" 0]
          added `shouldBe` False
        other -> expectationFailure ("expected a reaction notice, got: " <> show other)

  describe "history recovery" $ do
    it "keeps valid rows while counting malformed or cross-endpoint rows" $
      case parseHistoryMessages (UserId 1000) (GroupId 7777) historyPayload of
        Right ([historical], failures) -> do
          failures `shouldBe` 1
          historical.hmMessage.messageId `shouldBe` MessageId 9000
          historical.hmMessage.sender.userId `shouldBe` UserId 2001
          historical.hmMessage.sender.nickname `shouldBe` Nothing
          historical.hmMessageSeq `shouldBe` Just "cursor:41"
          historical.hmOccurredAt `shouldBe` posixSecondsToUTCTime 100
        other -> expectationFailure ("unexpected history parse result: " <> show other)

    it "drops the whole reconnect second and dedupes overlapping pages oldest-first" $ do
      let parsed = case parseHistoryMessages (UserId 1000) (GroupId 7777) selectionPayload of
            Right (messages, 0) -> messages
            other -> error ("history fixture did not parse: " <> show other)
          connectedAt = posixSecondsToUTCTime 101.75
          (selected, skippedAtCutoff) = selectHistoryBefore connectedAt parsed
      fmap ((.messageId) . (.hmMessage)) selected `shouldBe` [MessageId 8999, MessageId 9000]
      skippedAtCutoff `shouldBe` 1

pokeEvent :: [Pair] -> Value
pokeEvent extra =
  object $
    [ "post_type" .= ("notice" :: Text),
      "notice_type" .= ("notify" :: Text),
      "sub_type" .= ("poke" :: Text),
      "self_id" .= (1000 :: Int),
      "user_id" .= (2001 :: Int),
      "target_id" .= (1000 :: Int)
    ]
      <> extra

msgEvent :: Text -> [Pair] -> Value
msgEvent kind extra =
  object $
    [ "post_type" .= ("message" :: Text),
      "message_type" .= kind,
      "self_id" .= (1000 :: Int),
      "user_id" .= (2001 :: Int),
      "message_id" .= (9000 :: Int),
      "message" .= ([] :: [Value]),
      "raw_message" .= ("hi" :: Text),
      "sender" .= object ["user_id" .= (2001 :: Int), "nickname" .= ("Alice" :: Text)]
    ]
      <> extra

historyPayload :: Value
historyPayload =
  object
    [ "messages"
        .= [ historyMessage 7777 9000 100 ("cursor:41" :: Text),
             historyMessage 8888 9001 99 ("cursor:40" :: Text)
           ]
    ]

selectionPayload :: Value
selectionPayload =
  object
    [ "messages"
        .= [ historyMessage 7777 9000 100 (41 :: Int),
             historyMessage 7777 8999 99 (40 :: Int),
             historyMessage 7777 9000 100 (41 :: Int),
             historyMessage 7777 9002 101 (42 :: Int)
           ]
    ]

historyMessage :: (ToJSON a) => Int -> Int -> Int -> a -> Value
historyMessage group message time sequenceNumber =
  object
    [ "group_id" .= group,
      "user_id" .= (2001 :: Int),
      "message_id" .= message,
      "time" .= time,
      "message_seq" .= sequenceNumber,
      "message" .= ([] :: [Value]),
      "raw_message" .= ("hi" :: Text)
    ]
