module Max.Task.ExperienceSpec (spec) where

import Data.Either (isLeft)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Task.Experience
import Test.Hspec

spec :: Spec
spec = describe "task experience replay gate" $ do
  it "decodes list-valued capsule prose and preserves string-valued capsules" $ do
    let answer prose = TE.decodeUtf8 . LBS.toStrict . encode $ object
          ["description" .= capsule.description, "applicability" .= prose,
           "procedure" .= prose, "invalidations" .= prose, "evidence" .= capsule.evidence]
    parseExperienceResponse (answer (["first", "second"] :: [T.Text]))
      `shouldBe` Right (Just capsule {applicability = "- first\n- second", procedure = "- first\n- second", invalidations = "- first\n- second"})
    parseExperienceResponse (answer ("plain" :: T.Text))
      `shouldBe` Right (Just capsule {applicability = "plain", procedure = "plain", invalidations = "plain"})
    parseExperienceResponse (answer (object ["step" .= ("first" :: T.Text)])) `shouldSatisfy` isLeft
    parseExperienceResponse (answer ([1, 2] :: [Int])) `shouldSatisfy` isLeft
  it "accepts explicit abstention and leaves missing evidence to the semantic gate" $ do
    parseExperienceResponse "null" `shouldBe` Right Nothing
    let raw = TE.decodeUtf8 . LBS.toStrict . encode $ capsule {evidence = []}
    Right (Just decoded) <- pure (parseExperienceResponse raw)
    validateCapsule decoded `shouldSatisfy` isLeft
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
