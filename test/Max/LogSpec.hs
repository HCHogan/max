-- |
-- The log formatter's job is to stay readable after the colour is
-- gone, because that is the state it is read in most often — through
-- grep, a redirect, or a pager.  So the cases worth pinning are the
-- ones that only bite uncoloured: field separation, one line per
-- event, stable field order, and numbers that don't grow a @.0@.
module Max.LogSpec (spec) where

import Data.Aeson (Value (Null), object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Log (LogLevel (..), LogMessage (..))
import Max.Log (formatLogMessage)
import Test.Hspec

at :: UTCTime
at = UTCTime (fromGregorian 2026 7 26) (secondsToDiffTime (14 * 3600 + 32 * 60 + 7))

msg :: LogLevel -> [Text] -> Text -> Value -> LogMessage
msg lvl dom body dat =
  LogMessage
    { lmComponent = "max",
      lmDomain = dom,
      lmTime = at,
      lmLevel = lvl,
      lmMessage = body,
      lmData = dat
    }

plain :: LogMessage -> Text
plain = formatLogMessage False

spec :: Spec
spec = describe "Max.Log.formatLogMessage" $ do
  it "puts time, level, domain and message in fixed columns" $
    plain (msg LogInfo ["llm"] "llm dispatch" Null)
      `shouldBe` "14:32:07 INFO  llm      llm dispatch"

  it "renders the three levels log-base actually has" $ do
    let tag l = T.take 5 (T.drop 9 (plain (msg l [] "x" Null)))
    map tag [LogTrace, LogInfo, LogAttention] `shouldBe` ["TRACE", "INFO ", "WARN "]

  -- One space would do on a terminal, where the dim key colour marks
  -- the boundary.  Uncoloured it has to be two, or the message runs
  -- into its first field.
  it "separates the message from its fields by two spaces" $
    plain (msg LogInfo ["llm"] "llm dispatch" (object ["group_id" .= (7777 :: Int)]))
      `shouldBe` "14:32:07 INFO  llm      llm dispatch  group_id=7777"

  -- Aeson keeps every number as a Scientific, so ids print as 7777.0
  -- unless the integer case is handled.
  it "prints integers without a decimal tail" $
    plain (msg LogInfo [] "x" (object ["n" .= (7777 :: Int), "d" .= (1.5 :: Double)]))
      `shouldSatisfy` \t -> "n=7777 " `T.isInfixOf` (t <> " ") && "d=1.5" `T.isInfixOf` t

  -- aeson objects are unordered; a line whose fields shuffle between
  -- occurrences can't be diffed or scanned.
  it "orders fields deterministically" $ do
    let a = plain (msg LogInfo [] "x" (object ["z" .= (1 :: Int), "a" .= (2 :: Int), "m" .= (3 :: Int)]))
    a `shouldBe` "14:32:07 INFO           x  a=2 m=3 z=1"

  -- The whole point of the rewrite: one event is one line, so grep -A
  -- and grep -B mean what you expect.
  it "collapses a multi-line value onto one line" $ do
    let t = plain (msg LogInfo [] "group message" (object ["text" .= ("楼上俩难兄难弟\n建议直接烧了重买" :: Text)]))
    length (T.lines t) `shouldBe` 1
    t `shouldSatisfy` ("楼上俩难兄难弟⏎建议直接烧了重买" `T.isInfixOf`)

  it "quotes a value only when it could be read as more fields" $ do
    let f v = plain (msg LogInfo [] "x" (object ["k" .= (v :: Text)]))
    f "web_search" `shouldSatisfy` ("k=web_search" `T.isInfixOf`)
    f "timeout after 15s" `shouldSatisfy` ("k=\"timeout after 15s\"" `T.isInfixOf`)
    f "" `shouldSatisfy` ("k=\"\"" `T.isInfixOf`)

  it "omits the field section entirely when there is no data" $
    plain (msg LogAttention ["shutdown"] "drain timed out" Null)
      `shouldSatisfy` (not . ("  " `T.isSuffixOf`))

  -- Escapes occupy no columns, so padding has to measure what the
  -- terminal shows or every coloured line drifts out of alignment.
  it "aligns coloured and uncoloured lines identically" $ do
    let m' = msg LogInfo ["llm"] "llm dispatch" (object ["a" .= (1 :: Int)])
        stripped = T.filter (/= '\ESC') (T.concat (T.splitOn "[0m" (T.concat (T.splitOn "[2m" (T.concat (T.splitOn "[36m" (formatLogMessage True m')))))))
    stripped `shouldBe` plain m'
