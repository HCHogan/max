module Max.HistorianSpec (spec) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (TimeZone, UTCTime, minutesToTimeZone)
import Max.DB.History (HistoryItem (..), LedgerItem (..), MessageCursor (..))
import Max.Historian (renderHistorianSourceLine, takeEpisodeByToken)
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

  it "renders explicit principal, message, time, and reply provenance" $ do
    renderHistorianSourceLine
      timezone
      (HistoryItem 101 42 1000 (Just "Alice") Nothing "hello\nworld" testTime (Just 99))
      `shouldBe` "[2026-08-02 20:00 user_id=42 name=Alice message_id=101 reply_to=99]: hello ⏎ world"

ledger :: Int64 -> Int64 -> Bool -> Text -> LedgerItem
ledger seqNo message eligible body =
  LedgerItem
    (MessageCursor seqNo)
    (HistoryItem message 42 1000 (Just "Alice") Nothing body testTime Nothing)
    eligible

timezone :: TimeZone
timezone = minutesToTimeZone 480

testTime :: UTCTime
testTime = read "2026-08-02 12:00:00 UTC"
