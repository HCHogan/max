module OneBot.EventSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Types (Pair)
import Data.Text (Text)
import OneBot.Event (Event (..), GroupMessage (..), parseEvent)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = describe "parseEvent" $ do
  it "parses a group message with its real group id" $
    case parseEvent (msgEvent "group" ["group_id" .= (7777 :: Int)]) of
      Right (EvGroupMessage gm) -> do
        gm.groupId `shouldBe` GroupId 7777
        gm.userId `shouldBe` UserId 2001
      other -> expectationFailure ("expected EvGroupMessage, got: " <> show other)

  it "parses a private message onto the pseudo group id -user_id" $
    case parseEvent (msgEvent "private" []) of
      Right (EvGroupMessage gm) -> do
        gm.groupId `shouldBe` GroupId (-2001)
        gm.userId `shouldBe` UserId 2001
      other -> expectationFailure ("expected EvGroupMessage, got: " <> show other)

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
