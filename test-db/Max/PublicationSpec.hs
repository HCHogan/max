module Max.PublicationSpec (spec) where

import Control.Concurrent.STM
import Control.Exception (try)
import Data.IORef
import Data.Int (Int64)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..))
import Effectful (liftIO)
import Effectful.PostgreSQL (query)
import Helpers (insertRawMessage, testTime, truncateAll, withDb, withDbLog)
import Max.AgentEvent
import Max.DB.Connection (DbPool)
import Max.Effects.Outbound
import Max.IR
import Max.Platform.Types
import Max.ReplySend
import Max.Tools.Files (captionBody)
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "canonical publication boundaries" $ do
  it "never acknowledges a failed stream publication or spends its budget" $ do
    budget <- newTVarIO freshBudget
    result <-
      try $
        withDbLog pool $
          runOutboundWith (const (pure (PublicationFailed "injected"))) $
            handleAgentEvent
              (AgentOutputContext target (CanonicalMessageId 1) False budget)
              (AgentFinalStreamText "first paragraph\n\n")
    case result of
      Left (ReplyPublicationException err) -> err `shouldBe` "injected"
      Right _ -> expectationFailure "publication failure was acknowledged or swallowed"
    readTVarIO budget `shouldReturn` freshBudget

  it "retains the committed prefix and stops before publishing a later suffix" $ do
    calls <- newIORef (0 :: Int)
    result <-
      withDbLog pool
        $ runOutboundWith
          ( \_ -> do
              index <- liftIO (atomicModifyIORef' calls (\i -> (i + 1, i)))
              pure $ if index == 0 then Published (CanonicalMessageId 10) else PublicationFailed "second failed"
          )
        $ sendAndPersistReply target freshBudget "first\n\nsecond\n\nthird"
    result.committed `shouldBe` [CanonicalMessageId 10]
    result.failure `shouldBe` Just "second failed"
    result.budget.sbChunksLeft `shouldBe` freshBudget.sbChunksLeft - 1
    readIORef calls `shouldReturn` 2

  it "resolves caption mentions and scoped replies through the shared canonical resolver" $ do
    source <- insertRawMessage pool 100 900 123 9 testTime (Just "Alice") "source"
    [Only principal] <- withDb pool $ query "SELECT author_principal_id FROM messages WHERE canonical_message_id=?" (Only source)
    let caption = "[reply#" <> T.pack (show source) <> "] [mention#" <> T.pack (show (principal :: Int64)) <> ": Alice] hello"
    (reply, body) <- withDbLog pool (captionBody qqAdvertisedCaps (GroupId 900) (Just caption))
    reply `shouldBe` Just (CanonicalMessageId source)
    length [() | NMention {} <- body.nodes] `shouldBe` 1
    (foreignReply, _) <- withDbLog pool (captionBody qqAdvertisedCaps (GroupId 901) (Just caption))
    foreignReply `shouldBe` Nothing

  it "keeps reply-only captions and folds layout without leaking placeholders" $ do
    source <- insertRawMessage pool 100 900 123 9 testTime (Just "Alice") "source"
    withDbLog pool (captionBody qqAdvertisedCaps (GroupId 900) (Just ("[reply#" <> T.pack (show source) <> "]")))
      `shouldReturn` (Just (CanonicalMessageId source), Body [])
    withDbLog pool (captionBody qqAdvertisedCaps (GroupId 900) (Just "hello [split] world"))
      `shouldReturn` (Nothing, Body [NText "hello\nworld", NText "\n"])
    withDbLog pool (captionBody qqAdvertisedCaps (GroupId 900) Nothing)
      `shouldReturn` (Nothing, Body [])
  where
    target = ReplyTarget (GroupId 900) [] Nothing False False False False False Nothing
