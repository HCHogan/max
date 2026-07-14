module Max.UtilSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Max.Util (maxReplyChunks, splitReply)
import Test.Hspec

spec :: Spec
spec = describe "splitReply" $ do
  it "keeps a single paragraph as one message" $
    splitReply "就一句话" `shouldBe` ["就一句话"]

  it "splits on blank lines" $
    splitReply "第一段\n\n第二段\n还是第二段\n\n第三段"
      `shouldBe` ["第一段", "第二段\n还是第二段", "第三段"]

  it "treats whitespace-only lines as blank" $
    splitReply "a\n   \nb" `shouldBe` ["a", "b"]

  it "collapses runs of blank lines into one break" $
    splitReply "a\n\n\n\nb" `shouldBe` ["a", "b"]

  it "does not split inside code fences" $
    splitReply "看这段:\n\n```python\nx = 1\n\ny = 2\n```\n\n就这样"
      `shouldBe` ["看这段:", "```python\nx = 1\n\ny = 2\n```", "就这样"]

  it "caps chunk count, folding overflow into the last message" $ do
    let paras = [T.pack ("p" <> show i) | i <- [1 .. 9 :: Int]]
        out = splitReply (T.intercalate "\n\n" paras)
    length out `shouldBe` maxReplyChunks
    last out `shouldBe` T.intercalate "\n\n" (drop (maxReplyChunks - 1) paras)

  it "strips leading/trailing blank paragraphs" $
    splitReply "\n\nhello\n\n" `shouldBe` ["hello"]

  it "empty input yields one empty chunk (caller's concern)" $
    splitReply "" `shouldBe` [("" :: Text)]
