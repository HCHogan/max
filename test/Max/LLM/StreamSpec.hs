-- |
-- Recorded wire bytes, replayed.  The failure mode this guards against
-- isn't a crash — it's a reply that silently arrives truncated, or a
-- tool call whose arguments got dropped because a JSON fragment was
-- parsed before it was whole.
module Max.LLM.StreamSpec (spec) where

import Data.Aeson (Value (..), decodeStrict')
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Map.Strict qualified as Map
import Max.LLM.Stream
import Test.Hspec

-- | A recording, written as Text and encoded properly.  A ByteString
-- literal would truncate every non-ASCII char to one byte — the wire is
-- UTF-8, and a fixture that mangles it tests the wrong thing.
rec_ :: [Text] -> ByteString
rec_ = TE.encodeUtf8 . T.intercalate "\n\n"

-- | Feed a whole recording through, one frame at a time.
runWith :: (ByteString -> StreamAcc -> StreamAcc) -> ByteString -> StreamAcc
runWith step bytes = foldl (flip step) emptyAcc (fst (sseFrames bytes))

spec :: Spec
spec = do
  describe "sseFrames" $ do
    it "splits on the blank line and keeps the incomplete tail" $ do
      let (frames, rest) = sseFrames "data: one\n\ndata: tw"
      (frames, rest) `shouldBe` (["one"], "data: tw")

    -- Bytes arrive in whatever sizes the socket chooses, so the same
    -- stream cut anywhere must parse the same.
    it "gives the same frames however the bytes are split" $ do
      let whole = "data: a\n\ndata: b\n\ndata: c\n\n"
          feed (acc, buf) chunk =
            let (fs, rest) = sseFrames (buf <> chunk)
             in (acc <> fs, rest)
          pieces = [BC.take 1 (BC.drop i whole) | i <- [0 .. BC.length whole - 1]]
          (byteAtATime, leftover) = foldl feed ([], "") pieces
      byteAtATime `shouldBe` ["a", "b", "c"]
      leftover `shouldBe` ""

    it "strips exactly one space after the colon" $
      fst (sseFrames "data:  padded\n\n") `shouldBe` [" padded"]

    it "joins repeated data lines with a newline, per the spec" $
      fst (sseFrames "data: one\ndata: two\n\n") `shouldBe` ["one\ntwo"]

    -- Providers send `:` comment lines as keep-alives.  Treating one as
    -- an empty payload would append nothing but still count as a frame.
    it "ignores comment-only and dataless frames" $
      fst (sseFrames ": keep-alive\n\nevent: ping\n\ndata: real\n\n")
        `shouldBe` ["real"]

    it "tolerates CRLF" $
      fst (sseFrames "data: a\r\n\r\ndata: b\r\n\r\n") `shouldBe` ["a", "b"]

  describe "stepOpenAI" $ do
    let stream =
          rec_
            [ "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}",
              "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"上升沿\"}}]}",
              "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"圆角\"}}]}",
              "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}",
              "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":120,\"completion_tokens\":8,\"prompt_tokens_details\":{\"cached_tokens\":96}}}",
              "data: [DONE]",
              ""
            ]
        acc = runWith stepOpenAI stream

    it "concatenates content deltas in order" $
      acc.saText `shouldBe` "上升沿圆角"

    it "records the terminal usage frame" $
      (acc.saPromptTokens, acc.saCompletionTokens, acc.saCachedTokens)
        `shouldBe` (Just 120, Just 8, Just 96)

    it "marks a clean end" $
      acc.saDone `shouldBe` True

    -- The fragments are individually invalid JSON — `{"lo` parses as
    -- nothing.  Accumulating as text and parsing once is the whole
    -- reason PartialCall holds Text.
    it "reassembles tool-call arguments from fragments" $ do
      let toolStream =
            rec_
              [ "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"web_search\",\"arguments\":\"\"}}]}}]}",
                "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"q\\\":\"}}]}}]}",
                "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"\\\"探头\\\"}\"}}]}}]}",
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
                "data: [DONE]",
                ""
              ]
          calls = accToolCalls (runWith stepOpenAI toolStream)
      map pcName calls `shouldBe` ["web_search"]
      map pcId calls `shouldBe` ["call_a"]
      map pcArgs calls `shouldBe` ["{\"q\":\"探头\"}"]
      -- And it is valid JSON once whole.
      (decodeStrict' (TE.encodeUtf8 "{\"q\":\"探头\"}") :: Maybe Value)
        `shouldSatisfy` (/= Nothing)

    it "keeps parallel calls apart by index" $ do
      let two =
            rec_
              [ "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}},{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"g\",\"arguments\":\"{\"}}]}}]}",
                "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"}\"}}]}}]}",
                ""
              ]
          calls = accToolCalls (runWith stepOpenAI two)
      map (\c -> (c.pcId, c.pcName, c.pcArgs)) calls
        `shouldBe` [("a", "f", "{}"), ("b", "g", "{}")]

    -- A stream that just stops is the case that gets an interruption
    -- marker instead of a reply, so "did it finish" has to be honest.
    it "does not mark a truncated stream as done" $ do
      let cut = rec_ ["data: {\"choices\":[{\"delta\":{\"content\":\"半句\"}}]}", ""]
          a = runWith stepOpenAI cut
      (a.saText, a.saDone) `shouldBe` ("半句", False)

    -- DeepSeek streams its reasoning as a delta of its own, and the
    -- replayed assistant turn has to carry it back or the next request
    -- 400s.  It must never join saText: that is what goes to the group.
    it "keeps reasoning_content apart from the visible content" $ do
      let mixed =
            rec_
              [ "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"先想\"}}]}",
                "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"一下\"}}]}",
                "data: {\"choices\":[{\"delta\":{\"content\":\"答案是\"}}]}",
                ""
              ]
          a = runWith stepOpenAI mixed
      (a.saReasoning, a.saText) `shouldBe` ("先想一下", "答案是")

    it "survives an unfamiliar frame between real ones" $ do
      let noisy =
            rec_
              [ "data: {\"choices\":[{\"delta\":{\"content\":\"a\"}}]}",
                "data: {\"gateway\":\"keepalive\"}",
                "data: not json at all",
                "data: {\"choices\":[{\"delta\":{\"content\":\"b\"}}]}",
                ""
              ]
      (runWith stepOpenAI noisy).saText `shouldBe` "ab"

  describe "stepAnthropic" $ do
    let stream =
          rec_
            [ "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":120,\"cache_read_input_tokens\":96}}}",
              "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
              "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"我查\"}}",
              "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"一下\"}}",
              "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":8}}",
              "event: message_stop\ndata: {\"type\":\"message_stop\"}",
              ""
            ]
        acc = runWith stepAnthropic stream

    it "concatenates text_delta in order" $
      acc.saText `shouldBe` "我查一下"

    -- Anthropic splits usage across the first and last frames.
    it "takes input usage from the start and output from the end" $
      (acc.saPromptTokens, acc.saCachedTokens, acc.saCompletionTokens)
        `shouldBe` (Just 120, Just 96, Just 8)

    it "marks a clean end at message_stop" $
      acc.saDone `shouldBe` True

    it "reassembles a tool_use block's input_json_delta fragments" $ do
      let toolStream =
            rec_
              [ "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_x\",\"name\":\"view_image\"}}",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"id\\\":\"}}",
                "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"7405}\"}}",
                "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}",
                ""
              ]
          calls = accToolCalls (runWith stepAnthropic toolStream)
      map (\c -> (c.pcId, c.pcName, c.pcArgs)) calls
        `shouldBe` [("toolu_x", "view_image", "{\"id\":7405}")]

    -- Text and a tool call share one message, at different indices —
    -- that is how narration arrives alongside a call.
    it "keeps text and a tool call from the same message apart" $ do
      let mixed =
            rec_
              [ "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"我看一眼\"}}",
                "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"view_image\"}}",
                "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}",
                ""
              ]
          a = runWith stepAnthropic mixed
      a.saText `shouldBe` "我看一眼"
      map pcName (accToolCalls a) `shouldBe` ["view_image"]

    it "does not mark a truncated stream as done" $ do
      let cut = rec_ ["data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"半\"}}", ""]
          a = runWith stepAnthropic cut
      (a.saText, a.saDone) `shouldBe` ("半", False)

  describe "accToolCalls" $
    it "returns calls in wire index order, not map order" $ do
      let a =
            emptyAcc
              { saCalls =
                  Map.fromList
                    [ (2, PartialCall "c" "third" "{}"),
                      (0, PartialCall "a" "first" "{}"),
                      (1, PartialCall "b" "second" "{}")
                    ]
              }
      map pcName (accToolCalls a) `shouldBe` ["first", "second", "third"]
