module Max.Task.ExperienceSpec (spec) where

import Data.Either (isLeft)
import Data.Text qualified as T
import Max.Task.Experience
import Test.Hspec

spec :: Spec
spec = describe "task experience replay gate" $ do
  it "requires a scoped evidence capsule with applicability and invalidation conditions" $ do
    validateCapsule capsule `shouldBe` Right ()
    validateCapsule capsule {evidence = []} `shouldSatisfy` isLeft
    validateCapsule capsule {invalidations = ""} `shouldSatisfy` isLeft
    capsuleBody capsule `shouldSatisfy` T.isInfixOf "不授予工具权限"
  it "requires three distinct paired cases and an actual improvement without regression" $ do
    replayPasses report `shouldBe` True
    replayPasses report {cases = take 2 report.cases} `shouldBe` False
    replayPasses report {cases = replicate 3 (head report.cases)} `shouldBe` False
    replayPasses report {cases = [c {baseline = c.candidate} | c <- report.cases]} `shouldBe` False
  it "rejects missing evidence, forbidden output, unmeasured usage and excessive cost" $ do
    mapM_
      (\bad -> replayPasses report {cases = bad : tail report.cases} `shouldBe` False)
      [ (head report.cases) {candidate = "missing"},
        (head report.cases) {candidate = "ok deploy"},
        (head report.cases) {candidateTokens = 0},
        (head report.cases) {candidateTokens = 401}
      ]
  where
    capsule = ExperienceCapsule "检查版本再修复" "版本修复任务" "读取当前版本，按原值提交 CAS" "接口/版本语义改变" ["t#1:r1"]
    report = ReplayReport "capsule" "later" [ReplayCase prompt ["ok"] ["deploy"] "missing" "ok" 100 100 100 100 Nothing Nothing | prompt <- ["scope", "version", "evidence"]] "fake"
