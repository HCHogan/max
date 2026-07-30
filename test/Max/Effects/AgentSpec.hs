-- |
-- Narration is model-authored text sent on a path of its own, and it
-- drifted: the reply path grew placeholder handling and this one
-- didn't, so a literal @[↩#111091811]@ went out as visible text in the
-- group.  These pin the shared behaviour down on both sides.
module Max.Effects.AgentSpec (spec) where

import Control.Concurrent.STM (newTVarIO)
import Data.Set qualified as Set
import Max.Effects.Agent (DispatchContext (..), narrationSegments)
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

-- | A group dispatch triggered by message #7413.
ctx :: IO DispatchContext
ctx = do
  imgs <- newTVarIO (0, [])
  pure
    DispatchContext
      { dcGroupId = GroupId 7777,
        dcMessageId = MessageId 7413,
        dcUserId = UserId 2001,
        dcSelfId = UserId 1000,
        dcDebug = False,
        dcMultimodal = False,
        dcStickers = True,
        dcMentionable = Just (Set.fromList [UserId 2001, UserId 2002]),
        dcToolImages = imgs
      }

spec :: Spec
spec = describe "narrationSegments" $ do
  it "says nothing for blank narration" $ do
    dc <- ctx
    narrationSegments dc "   \n " `shouldBe` []

  -- Nothing auto-quotes any more: the reply path gave that up once the
  -- model proved it quotes on its own, and narration was the last
  -- holdout.
  it "sends plain text when the model named no quote target" $ do
    dc <- ctx
    narrationSegments dc "我查一下日志" `shouldBe` [SegText "我查一下日志"]

  -- The regression: this used to go out with the token visible.
  it "consumes a leading reply token instead of printing it" $ do
    dc <- ctx
    narrationSegments dc "[↩#111091811] wreq 是 Haskell 的 HTTP 客户端"
      `shouldBe` [ SegReply (MessageId 111091811),
                   SegText "wreq 是 Haskell 的 HTTP 客户端"
                 ]

  it "quotes what the model named" $ do
    dc <- ctx
    case narrationSegments dc "[↩#999] 看这条" of
      (SegReply m : _) -> m `shouldBe` MessageId 999
      other -> expectationFailure ("expected a reply segment: " <> show other)

  -- A poke has no trigger message at all; nothing changes, because
  -- nothing was quoting the trigger anyway.
  it "is unaffected by there being no trigger message" $ do
    dc <- ctx
    narrationSegments dc {dcMessageId = MessageId 0} "在看了"
      `shouldBe` [SegText "在看了"]

  it "converts mentions and keeps faces" $ do
    dc <- ctx
    narrationSegments dc "[@#2001] 稍等 [face#187]"
      `shouldBe` [ SegAt (UserId 2001),
                   SegText " 稍等 ",
                   SegFace 187 Nothing
                 ]

  -- Dropped, not printed: resolving either needs a DB round-trip, and
  -- a leaked "[sticker#42]" is worse than a missing sticker in a
  -- progress line.
  it "drops sticker and image placeholders rather than leaking them" $ do
    dc <- ctx
    narrationSegments dc "马上 [sticker#42] 好 [image#7405]"
      `shouldBe` [SegText "马上 ", SegText " 好"]

  -- Removing a token leaves a seam.  The reply path has always trimmed
  -- it; narration didn't, because it had its own copy of "turn model
  -- text into segments" — which is how it also missed the token
  -- handling.  Both now share 'trimEdgeSegs'.
  it "trims the space a consumed token leaves behind" $ do
    dc <- ctx
    narrationSegments dc "[↩#999] 稍等   "
      `shouldBe` [SegReply (MessageId 999), SegText "稍等"]

  it "leaves a malformed token alone" $ do
    dc <- ctx
    narrationSegments dc "看看 [↩#abc] 这个"
      `shouldBe` [SegText "看看 [↩#abc] 这个"]

  -- Streaming releases up to the last blank line, so a narration ending
  -- in "…\n\n[↩#999]" hands the tail sender a chunk that is only a
  -- quote.  Sending it posts an empty message wearing a quote; the
  -- reply path has always skipped a chunk that resolves to no content.
  it "says nothing for a chunk that is only a quote token" $ do
    dc <- ctx
    narrationSegments dc "[↩#999]" `shouldBe` []
    narrationSegments dc "[sticker#42]" `shouldBe` []
