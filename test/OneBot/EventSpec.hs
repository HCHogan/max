module OneBot.EventSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import OneBot.Event (Event (..), GroupMessage (..), PokeEvent (..), parseEvent)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = describe "parseEvent" $ do
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
