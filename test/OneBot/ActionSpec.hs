module OneBot.ActionSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Text (Text)
import OneBot.Action (Action (..), Envelope (..), encodeAction)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = describe "QQ history actions" $ do
  it "encodes an anchored group history page" $
    encodeAction (Envelope (GetGroupMsgHistory (GroupId 7777) (Just "41") 100) "echo-1")
      `shouldBe` object
        [ "action" .= ("get_group_msg_history" :: Text),
          "params"
            .= object
              [ "group_id" .= GroupId 7777,
                "message_seq" .= ("41" :: Text),
                "count" .= (100 :: Int),
                "reverse_order" .= False
              ],
          "echo" .= ("echo-1" :: Text)
        ]

  it "omits the optional cursor from a latest friend-history page" $
    encodeAction (Envelope (GetFriendMsgHistory (UserId 2001) Nothing 100) "echo-2")
      `shouldBe` object
        [ "action" .= ("get_friend_msg_history" :: Text),
          "params"
            .= object
              [ "user_id" .= UserId 2001,
                "count" .= (100 :: Int),
                "reverse_order" .= False
              ],
          "echo" .= ("echo-2" :: Text)
        ]

  describe "moderation actions" $ do
    it "recalls by message id alone; the group only routes the call" $
      encodeAction (Envelope (DeleteMsg (GroupId 7777) (MessageId 501)) "echo-3")
        `shouldBe` object
          [ "action" .= ("delete_msg" :: Text),
            "params" .= object ["message_id" .= MessageId 501],
            "echo" .= ("echo-3" :: Text)
          ]

    it "mutes a member for a duration in seconds" $
      encodeAction (Envelope (SetGroupBan (GroupId 7777) (UserId 2001) 600) "echo-4")
        `shouldBe` object
          [ "action" .= ("set_group_ban" :: Text),
            "params"
              .= object
                [ "group_id" .= GroupId 7777,
                  "user_id" .= UserId 2001,
                  "duration" .= (600 :: Int)
                ],
            "echo" .= ("echo-4" :: Text)
          ]
