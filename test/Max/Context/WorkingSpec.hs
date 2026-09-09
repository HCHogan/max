module Max.Context.WorkingSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Max.Context (estimateMessagesTokens)
import Max.Context.Working
import Max.LLM.Types (ChatMessage (..), ContentBlock (..), TokenUsage (..), ToolCall (..))
import Max.ModelCatalog (ContextLimits (..))
import Max.Tool.Types (ToolSpec (..))
import Test.Hspec hiding (fit)

spec :: Spec
spec = describe "recoverable working context" $ do
  it "keeps a below-watermark prefix byte stable" $ do
    let messages = [MsgSystem "rules", MsgUser "目标"] <> roundOf "1" "read" "answer"
    Right plan <- pure (fit Nothing messages [])
    map show plan.wpMessages `shouldBe` map show messages
    plan.wpCompacted `shouldBe` False

  it "compacts a long tool loop while preserving steering, skills and protocol pairs" $ do
    let steering = MsgUser "更正：不要部署，检查尚未完成"
        skill = roundOf "skill" "use_skill" "loaded instructions"
        messages = [MsgSystem "rules", MsgUser "原始目标"] <> concat [roundOf (T.pack (show n)) "read" (T.replicate 8000 "汉") | n <- [1 .. 10 :: Int]] <> skill <> [steering] <> roundOf "last" "read" "unfinished fact"
    Right plan <- pure (fit Nothing messages [])
    plan.wpCompacted `shouldBe` True
    plan.wpEstimatedTokens `shouldSatisfy` (<= plan.wpLimit)
    map show plan.wpMessages `shouldContain` [show steering]
    map show plan.wpMessages `shouldContain` map show skill
    map show plan.wpMessages `shouldContain` [show (MsgTool "last" "unfinished fact")]
    let calls = [tc.callId | MsgAssistantToolCalls _ tcs <- plan.wpMessages, tc <- tcs]
        results = [cid | MsgTool cid _ <- plan.wpMessages]
    results `shouldMatchList` calls
    plan.wpSummary `shouldSatisfy` T.isInfixOf "context_expand(handle=t#7, call_id="
    Right stable <- pure (fitWorkingContext limits Nothing "id" "t#7" plan.wpSummary plan.wpMessages [])
    stable.wpCompacted `shouldBe` False
    map show stable.wpMessages `shouldBe` map show plan.wpMessages

  it "handles repeated provider call ids and a single oversized newest result" $ do
    let messages = [MsgUser "keep goal"] <> concat [roundOf "0" "read" (T.replicate 20000 "x") | _ <- [1 .. 6 :: Int]]
    Right plan <- pure (fit Nothing messages [])
    plan.wpEstimatedTokens `shouldSatisfy` (<= plan.wpLimit)
    let calls = [call.callId | MsgAssistantToolCalls _ group <- plan.wpMessages, call <- group]
        results = [cid | MsgTool cid _ <- plan.wpMessages]
    calls `shouldMatchList` results
    Right latest <- pure (fit Nothing ([MsgUser "keep goal"] <> roundOf "0" "read" (T.replicate 100000 "汉")) [])
    latest.wpCompacted `shouldBe` True
    latest.wpSummary `shouldSatisfy` T.isInfixOf "call_id=0"

  it "counts dynamic schemas and media before calling the provider" $ do
    let messages = [MsgSystem "rules", MsgUser "目标"]
        huge = [ToolSpec "loaded" "instructions" (object ["schema" .= T.replicate 60000 "x"])]
    fit Nothing messages huge `shouldSatisfy` isLeft
    fit Nothing (messages <> [MsgUserBlocks [VideoDataUrl "data:video/mp4;base64,x", VideoDataUrl "data:video/mp4;base64,y"]]) [] `shouldSatisfy` isLeft

  it "does not spend the output reserve twice or drop an oversized protected goal" $ do
    let messages = [MsgUser "hello"]
        exact = ContextLimits (estimateMessagesTokens messages) 100000 0 0
    Right plan <- pure (fitWorkingContext exact Nothing "id" "t#7" "" messages [])
    plan.wpCompacted `shouldBe` False
    fit Nothing [MsgUser (T.replicate 50000 "原始目标")] [] `shouldSatisfy` isLeft

  it "allows protected instructions to consume soft headroom but respects a smaller model window" $ do
    let messages = [MsgUser (T.replicate 4000 "x")]
        large = ContextLimits 5000 1000 0 4000
        small = ContextLimits 1000 1000 0 0
    Right plan <- pure (fitWorkingContext large Nothing "large" "t#7" "" messages [])
    plan.wpCompacted `shouldBe` False
    plan.wpEstimatedTokens `shouldSatisfy` (<= plan.wpLimit)
    fitWorkingContext small Nothing "small" "t#7" "" messages [] `shouldSatisfy` isLeft

  it "anchors only unchanged prefixes under the same model/config/schema identity" $ do
    let prefix = [MsgUser "hello"]
        anchor = observeUsage "id" prefix (Just (TokenUsage 9000 100 (Just 8000)))
        longer = prefix <> [MsgAssistant "answer", MsgUser "steering"]
    requestTokens anchor "id" longer [] `shouldSatisfy` (> 9000)
    requestTokens anchor "changed" longer [] `shouldBe` requestTokens Nothing "changed" longer []
    requestTokens anchor "id" [MsgUser "modified"] [] `shouldBe` requestTokens Nothing "id" [MsgUser "modified"] []
    workingIdentity "large" "g1" limits [] `shouldNotBe` workingIdentity "small" "g1" limits []
    workingIdentity "large" "g1" limits [] `shouldNotBe` workingIdentity "large" "g2" limits []
    workingIdentity "large" "g1" limits [] `shouldNotBe` workingIdentity "large" "g1" limits [ToolSpec "a" "b" (object [])]

limits :: ContextLimits
limits = ContextLimits 12000 4000 2048 1000

fit :: Maybe UsageAnchor -> [ChatMessage] -> [ToolSpec] -> Either Text WorkingProjection
fit anchor messages = fitWorkingContext limits anchor "id" "t#7" "" messages

roundOf :: Text -> Text -> Text -> [ChatMessage]
roundOf cid name content = [MsgAssistantToolCalls (object []) [ToolCall cid name (object [])], MsgTool cid content]
