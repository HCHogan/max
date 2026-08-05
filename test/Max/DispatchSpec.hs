-- | Who a canonical message addresses, on every platform.
--
-- The bot's compatibility id and its native id are the same number only on
-- QQ.  Everywhere else the compatibility id is a synthetic bigint, so a
-- trigger check written against it answers "not addressed" to every @ the
-- bot will ever receive there.  ADR 004 settles it by comparing /people/:
-- whichever account carried the mention, the principal behind it is the same.
module Max.DispatchSpec (spec) where

import Data.Map.Strict qualified as Map
import Max.Dispatch
import Max.IR
import Max.Platform.Types
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

spec :: Spec
spec = describe "canonical dispatch addressing" $ do
  it "sees an @ of the bot on QQ" $ do
    let message = qq [NMention (MentionIdentity (PrincipalIdentityId 1)) "Max", NText " 在吗"]
    dispatchMentionsSelf message `shouldBe` True

  it "sees an @ of the bot's Matrix account, which is a different account" $ do
    let message = matrix [NMention (MentionIdentity (PrincipalIdentityId 11)) "Max", NText " help"]
    dispatchMentionsSelf message `shouldBe` True

  it "ignores an @ of somebody else" $ do
    let message = matrix [NMention (MentionIdentity (PrincipalIdentityId 2)) "Alice", NText " help"]
    dispatchMentionsSelf message `shouldBe` False

  it "treats a mention of everyone as addressing the bot" $ do
    let message = matrix [NMention MentionAll "@room", NText " 上线了"]
    dispatchMentionsSelf message `shouldBe` True

  describe "the text the command parser and the current line see" $ do
    it "renders a mention as the person's canonical handle" $ do
      let message = qq [NMention (MentionIdentity (PrincipalIdentityId 2)) "Alice", NText " 在吗"]
      dispatchText message `shouldBe` "[@#2] 在吗"

    it "drops the bot's own mention on QQ" $ do
      let message = qq [NMention (MentionIdentity (PrincipalIdentityId 1)) "Max", NText " !status"]
      dispatchTextWithoutSelf message `shouldBe` "!status"

    it "drops it on Matrix, through the bot's other account" $ do
      let message = matrix [NMention (MentionIdentity (PrincipalIdentityId 11)) "Max", NText " help"]
      dispatchText message `shouldBe` "[@#1] help"
      dispatchTextWithoutSelf message `shouldBe` "help"

    it "keeps mentions of other people" $ do
      let message =
            matrix
              [ NMention (MentionIdentity (PrincipalIdentityId 11)) "Max",
                NText " 转告 ",
                NMention (MentionIdentity (PrincipalIdentityId 2)) "Alice"
              ]
      dispatchTextWithoutSelf message `shouldBe` "转告 [@#2]"

    it "falls back to @name when a mention resolves to nobody" $ do
      let message = qq [NMention (MentionIdentity (PrincipalIdentityId 99)) "Ghost", NText " ?"]
      dispatchText message `shouldBe` "@Ghost ?"

-- | Identity 1 is the bot's QQ account, 11 its Matrix account; both belong to
-- principal 1, which is the merge this ADR leaves the seam open for.
qq :: [Node 'Canonical] -> DispatchMessage
qq = dispatchOn PlatformQQ (UserId 10086)

-- | A Matrix endpoint's compatibility self id is a synthetic negative bigint
-- that shares nothing with the bot's QQ number.
matrix :: [Node 'Canonical] -> DispatchMessage
matrix = dispatchOn PlatformMatrix (UserId (-1000000000001))

dispatchOn :: Platform -> UserId -> [Node 'Canonical] -> DispatchMessage
dispatchOn platform self nodes =
  DispatchMessage
    { selfId = self,
      groupId = GroupId 42,
      userId = UserId 2001,
      selfPrincipalId = PrincipalId 1,
      authorPrincipalId = PrincipalId 2,
      canonicalId = CanonicalMessageId 9000,
      body = Body nodes,
      replyTo = Nothing,
      senderDisplayName = Just "Alice",
      sourcePlatform = platform,
      mentionPrincipals =
        Map.fromList
          [ (PrincipalIdentityId 1, PrincipalId 1),
            (PrincipalIdentityId 11, PrincipalId 1),
            (PrincipalIdentityId 2, PrincipalId 2)
          ]
    }
