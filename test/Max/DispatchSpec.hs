-- | Who a canonical message addresses, on every platform.
--
-- The bot's compatibility id and its native id are the same number only on
-- QQ.  Everywhere else the compatibility id is a synthetic bigint, so a
-- trigger check written against it answers "not addressed" to every @ the
-- bot will ever receive there.
module Max.DispatchSpec (spec) where

import Data.Map.Strict qualified as Map
import Max.Dispatch
import Max.IR
import Max.Platform.Types
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = describe "canonical dispatch addressing" $ do
  it "sees an @ of the bot's QQ number" $ do
    let message = qq [NMention (MentionIdentity (PrincipalIdentityId 1)) "10086", NText " 在吗"]
    dispatchMentionsSelf message `shouldBe` True

  it "sees an @ of the bot's Matrix id" $ do
    let message = matrix [NMention (MentionIdentity (PrincipalIdentityId 1)) "@max:test", NText " help"]
    dispatchMentionsSelf message `shouldBe` True

  it "ignores an @ of somebody else" $ do
    let message = matrix [NMention (MentionIdentity (PrincipalIdentityId 2)) "@alice:test", NText " help"]
    dispatchMentionsSelf message `shouldBe` False

  it "treats a mention of everyone as addressing the bot" $ do
    let message = matrix [NMention MentionAll "@room", NText " 上线了"]
    dispatchMentionsSelf message `shouldBe` True

  describe "the text the command parser and the current line see" $ do
    it "drops the bot's own mention on QQ" $ do
      let message = qq [NMention (MentionIdentity (PrincipalIdentityId 1)) "10086", NText " !status"]
      dispatchTextWithoutSelf message `shouldBe` "!status"

    it "drops it on Matrix, where it never rendered as an id" $ do
      let message = matrix [NMention (MentionIdentity (PrincipalIdentityId 1)) "@max:test", NText " help"]
      dispatchText message `shouldBe` "@max:test help"
      dispatchTextWithoutSelf message `shouldBe` "help"

    it "keeps mentions of other people" $ do
      let message =
            matrix
              [ NMention (MentionIdentity (PrincipalIdentityId 1)) "@max:test",
                NText " 转告 ",
                NMention (MentionIdentity (PrincipalIdentityId 2)) "@alice:test"
              ]
      dispatchTextWithoutSelf message `shouldBe` "转告 @alice:test"

qq :: [Node 'Canonical] -> DispatchMessage
qq = dispatchOn PlatformQQ (UserId 10086) (NativeAccountId "10086") (NativeUserId "10086")

-- | A Matrix endpoint's compatibility self id is a synthetic negative bigint
-- that shares nothing with @\@max:test@.
matrix :: [Node 'Canonical] -> DispatchMessage
matrix = dispatchOn PlatformMatrix (UserId (-1000000000001)) (NativeAccountId "@max:test") (NativeUserId "@max:test")

dispatchOn :: Platform -> UserId -> NativeAccountId -> NativeUserId -> [Node 'Canonical] -> DispatchMessage
dispatchOn platform self selfNative selfMentionNative nodes =
  DispatchMessage
    { selfId = self,
      selfNative,
      groupId = GroupId 42,
      userId = UserId 2001,
      messageId = MessageId 9000,
      body = Body nodes,
      replyToMessageId = Nothing,
      senderDisplayName = Just "Alice",
      sourcePlatform = platform,
      mentionNatives =
        Map.fromList
          [ (PrincipalIdentityId 1, selfMentionNative),
            (PrincipalIdentityId 2, NativeUserId "@alice:test")
          ]
    }
