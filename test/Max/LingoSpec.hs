module Max.LingoSpec (spec) where

import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Max.Lingo.Policy
import Max.Lingo.Types
import Test.Hspec

spec :: Spec
spec = describe "Max.Lingo.Policy" $ do
  describe "parseLearnedBatch" $ do
    it "reads fenced JSON and tolerates quoted source ids" $ do
      let raw = "```json\n{\"expressions\": [{\"situation\": \"讽刺地赞同\", \"style\": \"用 对对对\", \"source_id\": \"2\"}], \"jargon\": [{\"term\": \"典\", \"source_id\": 3}]}\n```"
      parseLearnedBatch raw
        `shouldBe` Right (LearnedBatch [RawExpression "讽刺地赞同" "用 对对对" (Just 2)] [RawJargon "典" (Just 3)])

    it "treats missing arrays as empty and rejects responses without an object" $ do
      parseLearnedBatch "{\"expressions\": []}" `shouldBe` Right (LearnedBatch [] [])
      parseLearnedBatch "没有找到" `shouldSatisfy` either (const True) (const False)

  describe "acceptExpressions" $ do
    it "keeps member habits with their spoken example and drops Max's own lines" $ do
      let accepted =
            acceptExpressions
              sources
              [ RawExpression "讽刺地赞同" "用 对对对" (Just 2),
                RawExpression "自我介绍" "说 我是鲨鱼" (Just 1),
                RawExpression "无来源" "用 啊对" Nothing,
                RawExpression "越界" "用 好好好" (Just 99)
              ]
      accepted `shouldBe` [ExpressionObservation "讽刺地赞同" "用 对对对" "用对对对" 102 "对对对，你说的都对"]

    it "rejects platform markers, overlong phrases and duplicate styles" $ do
      let accepted =
            acceptExpressions
              sources
              [ RawExpression "发图" "[image]" (Just 2),
                RawExpression (T.replicate 41 "长") "用 长" (Just 2),
                RawExpression "讽刺地赞同" "用 对对对" (Just 2),
                RawExpression "敷衍" "用「对对对」" (Just 3)
              ]
      map (.eoStyle) accepted `shouldBe` ["用 对对对"]

  describe "acceptJargon" $ do
    it "requires the term in a member's own words, outside links and markers" $ do
      let accepted =
            acceptJargon
              sources
              [ RawJargon "典" (Just 3),
                RawJargon "token" (Just 4),
                RawJargon "鲨鱼" (Just 1),
                RawJargon "不存在" (Just 3)
              ]
      map (.joTerm) accepted `shouldBe` ["典"]

    it "records who said it and the line before it" $ do
      case acceptJargon sources [RawJargon "「典」" (Just 3)] of
        [observation] -> do
          observation.joTerm `shouldBe` "典"
          observation.joPrincipal `shouldBe` 20
          observation.joContext `shouldBe` "阿飞：对对对，你说的都对\n老张：又开始了，典"
        other -> expectationFailure (show other)

    it "rejects speaker names and latin terms inside longer words" $ do
      let named = [LingoSource 1 201 20 "老张" False "老张说 ds 模型不错，friends 都在用"]
      map (.joTerm) (acceptJargon named [RawJargon "老张" (Just 1), RawJargon "ds" (Just 1), RawJargon "end" (Just 1)])
        `shouldBe` ["ds"]

  describe "inference thresholds" $ do
    it "infers at each threshold once, and only after two speakers" $ do
      needsInference 3 0 5 `shouldBe` False
      needsInference 4 0 1 `shouldBe` False
      needsInference 4 0 2 `shouldBe` True
      needsInference 7 4 2 `shouldBe` False
      needsInference 8 4 2 `shouldBe` True
      needsInference 30 8 3 `shouldBe` True

    it "parses the contextual answer, discarding group-specific claims without information" $ do
      parseContextualMeaning "{\"meaning\": \"反讽，说事情离谱得很典型\", \"group_specific\": true, \"no_info\": false}"
        `shouldBe` Just (JargonInference (Just "反讽，说事情离谱得很典型") True)
      parseContextualMeaning "{\"meaning\": \"\", \"group_specific\": true, \"no_info\": true}"
        `shouldBe` Just (JargonInference Nothing False)
      parseGeneralMeaning "{\"meaning\": \" 经典 \"}" `shouldBe` Just "经典"

  describe "stylePhrases" $ do
    it "takes quoted spans, empty brackets, or the word after the verb" $ do
      stylePhrases "用「难绷」" `shouldBe` ["难绷"]
      stylePhrases "用“没绷住“" `shouldBe` ["没绷住"]
      stylePhrases "「所以说」开头＋（）收尾" `shouldBe` ["所以说", "（）"]
      stylePhrases "句尾加()" `shouldBe` ["（）"]
      stylePhrases "用 我去" `shouldBe` ["我去"]
      stylePhrases "用 Emmm" `shouldBe` ["emmm"]
      stylePhrases "神了" `shouldBe` ["神了"]

    it "drops single characters" $ do
      stylePhrases "单独发一个“？”" `shouldBe` []
      stylePhrases "直接发一个 6" `shouldBe` []

  describe "sampleExpressions" $ do
    let pool = [LingoExpression i ("场景" <> tshowInt i) ("说法" <> tshowInt i <> "号") (fromIntegral (if i <= 5 then 40 else 1)) "例" | i <- [1 .. 50]]
    it "is deterministic per seed and never repeats an entry" $ do
      let picked = sampleExpressions 42 6 [] pool
      picked `shouldBe` sampleExpressions 42 6 [] pool
      length picked `shouldBe` 6
      length (Map.fromList [(e.leId, ()) | e <- picked]) `shouldBe` 6

    it "favours established expressions across seeds" $ do
      let heavy = length [() | seed <- [1 .. 200], e <- sampleExpressions seed 6 [] pool, e.leId <= 5]
      -- 5 of 50 entries carry 200 of 245 weight; uniform sampling would pick ~120.
      heavy `shouldSatisfy` (> 600)

    it "leaves out habits Max's own recent lines already show" $ do
      let picked = sampleExpressions 7 4 ["[↩#12] 拿鸡毛当令箭是吧（）", "这也太难绷了"] habits
      map (.leStyle) picked `shouldMatchList` ["用“没绷住”", "用 我去"]

    it "never puts two variants of one wording in a sample" $ do
      let picked = [e.leStyle | seed <- [1 .. 50], e <- sampleExpressions seed 4 [] habits, "难绷" `T.isInfixOf` e.leStyle]
          perSample = [length [() | e <- sampleExpressions seed 4 [] habits, "难绷" `T.isInfixOf` e.leStyle] | seed <- [1 .. 50]]
      picked `shouldSatisfy` (not . null)
      maximum perSample `shouldBe` 1

  describe "overusedPhrases" $ do
    it "names wordings in at least two recent lines, most repeated first, one per family" $
      overusedPhrases ["难绷了（）", "难绷", "这也难绷()", "没绷住", "我去"] habits `shouldBe` ["难绷", "（）"]

    it "is empty when Max varies its wording" $
      overusedPhrases ["难绷", "没绷住", "我去（）"] habits `shouldBe` []

  describe "matchJargon" $ do
    let known = [LingoJargon "典" "反讽" 30, LingoJargon "ds" "DeepSeek" 12, LingoJargon "炸鸡" "烧坏板子" 5]
    it "returns terms used recently, newest mention first" $
      map (.ljTerm) (matchJargon 4 ["昨天又炸鸡了", "这也行，典"] known) `shouldBe` ["典", "炸鸡"]

    it "ignores links, markers and latin substrings" $
      matchJargon 4 ["看 https://ds.example.com [image#12.0: ds 截图] friends"] known `shouldBe` []

    it "caps the number of terms" $
      sort (map (.ljTerm) (matchJargon 2 ["典", "ds 不错", "炸鸡"] known)) `shouldBe` ["ds", "炸鸡"]

sources :: [LingoSource]
sources =
  [ LingoSource 1 101 1 "Max" True "我是鲨鱼，不是机器人",
    LingoSource 2 102 10 "阿飞" False "对对对，你说的都对",
    LingoSource 3 103 20 "老张" False "又开始了，典",
    LingoSource 4 104 10 "阿飞" False "看这个 https://tokenhub.example.com/token [image#104.0: 截图]"
  ]

-- | A family of 难绷 variants, a bracket habit and two unrelated wordings.
habits :: [LingoExpression]
habits =
  [ LingoExpression 1 "表示无语" "用「难绷」" 8 "难绷",
    LingoExpression 2 "表示无语" "直接说“难绷”" 3 "难绷",
    LingoExpression 3 "表示无语" "用 难绷了" 2 "难绷了",
    LingoExpression 4 "被离谱内容整无语" "用“没绷住”" 8 "没绷住",
    LingoExpression 5 "表示无语或轻蔑" "句末加（）" 9 "那确实（）",
    LingoExpression 6 "表示惊讶" "用 我去" 5 "我去"
  ]

tshowInt :: (Show a) => a -> Text
tshowInt = T.pack . show
