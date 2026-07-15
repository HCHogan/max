module Max.RenderSpec (spec) where

import Data.ByteString qualified as BS
import Max.Render (renderTableImage)
import Test.Hspec

-- Exercises the real typst CLI — present in the dev shell (and CI
-- runs inside it).  Content correctness is eyeballed; here we only
-- assert "a PNG came out".
spec :: Spec
spec = describe "renderTableImage" $ do
  it "renders a markdown table to a PNG" $ do
    r <- renderTableImage "| 名称 | 值 |\n|---|---:|\n| 速度 | 3×10⁸ |"
    case r of
      Left err -> expectationFailure ("render failed: " <> show err)
      Right png -> BS.take 4 png `shouldBe` BS.pack [0x89, 0x50, 0x4E, 0x47]

  it "rejects input without a separator row" $ do
    r <- renderTableImage "just some text"
    case r of
      Left _ -> pure ()
      Right _ -> expectationFailure "expected Left for non-table input"
