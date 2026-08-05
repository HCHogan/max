module Max.HistorianSpec (spec) where

import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone, UTCTime, minutesToTimeZone)
import Effectful (liftIO, runEff)
import Max.DB.History (HistoryItem (..), LedgerItem (..), MessageCursor (..))
import Max.Effects.LLM (ChatMessage (..), ChatResponse (..), LLMInterpreter (..), runLLMWith)
import Max.Historian (generateHistorianCapture, historianRetryDelaySeconds, renderHistorianSourceLine, takeEpisodeByToken)
import Test.Hspec

spec :: Spec
spec = describe "Historian token and identity policy" $ do
  it "selects a token-bounded prefix rather than a fixed message count" $ do
    let rows =
          [ ledger 1 101 True "short",
            ledger 2 102 True (mconcat (replicate 2000 "long discussion ")),
            ledger 3 103 True "never reached"
          ]
    map (.cursor) (takeEpisodeByToken timezone 32 rows)
      `shouldBe` [MessageCursor 1]
    map (.cursor) (takeEpisodeByToken timezone 100_000 rows)
      `shouldBe` map MessageCursor [1, 2, 3]

  it "keeps ledger-only rows in coverage even though they cost almost no transcript budget" $ do
    let rows =
          [ ledger 1 101 False "!command",
            ledger 2 102 True "visible"
          ]
    map (.cursor) (takeEpisodeByToken timezone 1 rows)
      `shouldBe` [MessageCursor 1]

  it "backs durable failures off without ever dropping their exact range" $ do
    map historianRetryDelaySeconds [1 .. 8]
      `shouldBe` [60, 300, 900, 3600, 21600, 21600, 21600, 21600]

  it "renders explicit principal, message, time, and reply provenance" $ do
    renderHistorianSourceLine
      timezone
      (HistoryItem 101 42 False (Just "Alice") Nothing "hello\nworld" testTime (Just 99))
      `shouldBe` "[2026-08-02 20:00 principal_id=42 name=Alice message_id=101 reply_to=99]: hello ⏎ world"

  it "repairs one malformed structured response with the same production policy" $ do
    calls <- newIORef (0 :: Int)
    result <-
      runEff
        . runLLMWith
          LLMInterpreter
            { liChat = \_ _ messages _ _ -> liftIO $ do
                attempt <- atomicModifyIORef' calls (\count -> (count + 1, count))
                if attempt == 0
                  then pure (Right (ContentResp "{broken"))
                  else do
                    messages `shouldSatisfy` \case
                      [MsgSystem _, MsgUser _, MsgAssistant raw, MsgUser repair] ->
                        raw == "{broken" && "JSON number" `T.isInfixOf` repair
                      _ -> False
                    pure (Right (ContentResp validRawCapture))
            }
        $ generateHistorianCapture 600 "test" 7 [MsgSystem "system", MsgUser "source"]
    result `shouldSatisfy` \case Right (_, _) -> True; _ -> False
    readIORef calls `shouldReturn` 2

ledger :: Int64 -> Int64 -> Bool -> Text -> LedgerItem
ledger seqNo message eligible body =
  LedgerItem
    (MessageCursor seqNo)
    (HistoryItem message 42 False (Just "Alice") Nothing body testTime Nothing)
    eligible

timezone :: TimeZone
timezone = minutesToTimeZone 480

testTime :: UTCTime
testTime = read "2026-08-02 12:00:00 UTC"

validRawCapture :: Text
validRawCapture =
  "{\"summary_p1\":{\"text\":\"full\",\"evidence_message_ids\":[11]},\"summary_p2\":{\"text\":\"compact\",\"evidence_message_ids\":[11]},\"summary_p3\":{\"text\":\"anchor\",\"evidence_message_ids\":[11]},\"importance\":0.7,\"confidence\":0.8,\"episode_kind\":\"ambient\",\"memory_proposals\":[]}"
