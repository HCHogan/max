module Max.YouTubeSpec (spec) where

import Data.Aeson (Value, decodeStrict')
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.YouTube
import Test.Hspec

json :: Text -> Value
json = fromJust . decodeStrict' . TE.encodeUtf8

track :: Text -> Bool -> CaptionTrack
track language auto = CaptionTrack ("https://www.youtube.com/api/timedtext?lang=" <> language) language language auto

video :: [CaptionTrack] -> Maybe Int -> YouTubeVideo
video tracks original = YouTubeVideo "oTDcJcvrfCU" "t" "c" 60 Nothing "" False tracks original

spec :: Spec
spec = do
  describe "findYouTubeId" $ do
    it "reads a watch link with extra parameters" $
      findYouTubeId "看这个 https://www.youtube.com/watch?app=desktop&v=oTDcJcvrfCU&t=42s 讲得好"
        `shouldBe` Just "oTDcJcvrfCU"

    it "reads youtu.be share links" $
      findYouTubeId "https://youtu.be/jlJyuJhDnlc?si=piKS9dc5FIzV1ySM" `shouldBe` Just "jlJyuJhDnlc"

    it "reads shorts, live and mobile links" $ do
      findYouTubeId "https://youtube.com/shorts/abcdefghijk?feature=share" `shouldBe` Just "abcdefghijk"
      findYouTubeId "https://www.youtube.com/live/A_b-C_d-E_f" `shouldBe` Just "A_b-C_d-E_f"
      findYouTubeId "https://m.youtube.com/watch?v=oTDcJcvrfCU" `shouldBe` Just "oTDcJcvrfCU"

    it "accepts a bare ID" $
      findYouTubeId " oTDcJcvrfCU " `shouldBe` Just "oTDcJcvrfCU"

    it "rejects IDs of the wrong length and unrelated text" $ do
      findYouTubeId "https://youtu.be/short" `shouldBe` Nothing
      findYouTubeId "https://www.youtube.com/watch?v=oTDcJcvrfCUx" `shouldBe` Nothing
      findYouTubeId "今天天气不错" `shouldBe` Nothing

  describe "parsePlayer" $ do
    it "reads details, tracks and the spoken-language track" $ do
      let v =
            json
              "{\"playabilityStatus\":{\"status\":\"OK\"},\
              \\"videoDetails\":{\"videoId\":\"oTDcJcvrfCU\",\"title\":\"How Agents Quietly Break Architecture\",\
              \\"author\":\"LambdaX.1\",\"lengthSeconds\":\"1198\",\"viewCount\":\"35848\",\
              \\"shortDescription\":\"German dude\",\"isLiveContent\":false},\
              \\"captions\":{\"playerCaptionsTracklistRenderer\":{\"captionTracks\":[\
              \{\"baseUrl\":\"https://x/a\",\"name\":{\"runs\":[{\"text\":\"Arabic (auto-generated)\"}]},\"languageCode\":\"ar\",\"kind\":\"asr\",\"isTranslatable\":true},\
              \{\"baseUrl\":\"https://x/e\",\"name\":{\"simpleText\":\"English (auto-generated)\"},\"languageCode\":\"en\",\"kind\":\"asr\",\"isTranslatable\":true}],\
              \\"audioTracks\":[{\"captionTrackIndices\":[1,0]}],\"defaultAudioTrackIndex\":0}}}"
      case parsePlayer v of
        Left err -> expectationFailure (T.unpack err)
        Right parsed -> do
          parsed.ytTitle `shouldBe` "How Agents Quietly Break Architecture"
          parsed.ytChannel `shouldBe` "LambdaX.1"
          parsed.ytDurationSec `shouldBe` 1198
          parsed.ytViews `shouldBe` Just 35848
          map ctName parsed.ytTracks `shouldBe` ["Arabic (auto-generated)", "English (auto-generated)"]
          parsed.ytOriginal `shouldBe` Just 1

    it "reports the refusal when there are no details" $
      parsePlayer (json "{\"playabilityStatus\":{\"status\":\"LOGIN_REQUIRED\",\"reason\":\"Sign in\"}}")
        `shouldBe` Left "YouTube 拒绝: LOGIN_REQUIRED — Sign in"

  describe "pickTrack" $ do
    let tracks = [track "ar" True, track "en" True, track "zh-Hans" False]
    it "prefers uploaded Chinese captions, else the spoken language" $ do
      ctLanguage <$> pickTrack Nothing (video tracks (Just 1)) `shouldBe` Just "zh-Hans"
      ctLanguage <$> pickTrack Nothing (video (take 2 tracks) (Just 1)) `shouldBe` Just "en"

    it "matches a requested language by prefix" $ do
      ctLanguage <$> pickTrack (Just "AR") (video tracks (Just 1)) `shouldBe` Just "ar"
      ctLanguage <$> pickTrack (Just "zh") (video tracks (Just 1)) `shouldBe` Just "zh-Hans"

    it "falls back to the default choice when the request has no track" $
      ctLanguage <$> pickTrack (Just "ja") (video (take 2 tracks) (Just 1)) `shouldBe` Just "en"

  describe "transcripts" $ do
    let cues =
          either (error . T.unpack) id . parseTranscript . json $
            "{\"events\":[{\"tStartMs\":0,\"segs\":[{\"utf8\":\"\\n\"}]},\
            \{\"tStartMs\":400,\"segs\":[{\"utf8\":\"My\"},{\"utf8\":\" problem\"}]},\
            \{\"tStartMs\":2390,\"aAppend\":1,\"segs\":[{\"utf8\":\"\\n\"}]},\
            \{\"tStartMs\":2400,\"segs\":[{\"utf8\":\"is agents\"}]},\
            \{\"tStartMs\":61000,\"segs\":[{\"utf8\":\"later\"}]},\
            \{\"tStartMs\":3725000,\"segs\":[{\"utf8\":\"一小时后\"}]},\
            \{\"tStartMs\":3726000,\"segs\":[{\"utf8\":\"还在讲\"}]}]}"
    it "drops blank cues" $
      map tlStartMs cues `shouldBe` [400, 2400, 61000, 3725000, 3726000]

    it "groups cues into timestamped minute paragraphs" $
      renderTranscript 0 40000 cues
        `shouldBe` ("[00:00] My problem is agents\n[01:01] later\n[1:02:05] 一小时后还在讲", Nothing)

    it "stops at the budget and says where to resume" $ do
      renderTranscript 0 45 cues `shouldBe` ("[00:00] My problem is agents\n[01:01] later", Just 3725)
      renderTranscript 3725 40000 cues `shouldBe` ("[1:02:05] 一小时后还在讲", Nothing)
