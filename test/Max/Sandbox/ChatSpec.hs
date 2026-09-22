module Max.Sandbox.ChatSpec (spec) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Sandbox.Chat
import Test.Hspec

spec :: Spec
spec = describe "/chat names" $ do
  it "turns an image handle into its path plus the stored type" $ do
    chatMediaName ChatImage 123 0 (Just "image/jpeg") `shouldBe` "123.0.jpg"
    chatMediaName ChatImage 123 2 (Just "image/png") `shouldBe` "123.2.png"
    chatMediaName ChatVideo 77 1 (Just "video/mp4") `shouldBe` "77.1.mp4"
    chatMediaName ChatVideo 77 1 (Just "video/quicktime") `shouldBe` "77.1.mov"
    chatMediaName ChatImage 5 0 (Just "image/svg+xml") `shouldBe` "5.0.bin"
    chatMediaName ChatImage 5 0 Nothing `shouldBe` "5.0.bin"
  it "prefixes files with their message and numbers only messages with several" $ do
    chatFileNames 456 ["report.pdf"] `shouldBe` ["456-report.pdf"]
    chatFileNames 456 ["a.pdf", "b.pdf"] `shouldBe` ["456.0-a.pdf", "456.1-b.pdf"]
    chatFileNames (-9) ["x"] `shouldBe` ["-9-x"]
  it "keeps display names readable but one safe path component" $ do
    chatFileNames 1 ["../../etc/passwd"] `shouldBe` ["1-.._.._etc_passwd"]
    chatFileNames 1 ["a\nb\\c.txt"] `shouldBe` ["1-a_b_c.txt"]
    chatFileNames 1 ["  "] `shouldBe` ["1-file"]
    chatFileNames 1 ["季度报告（终版）.xlsx"] `shouldBe` ["1-季度报告（终版）.xlsx"]
  it "shortens long names at a character boundary and keeps the extension" $ do
    let ascii = chatFileNames 1 [T.replicate 300 "a" <> ".pdf"]
        wide = chatFileNames 1 [T.replicate 300 "报" <> ".docx"]
    ascii `shouldSatisfy` all (T.isSuffixOf ".pdf")
    wide `shouldSatisfy` all (T.isSuffixOf "报.docx")
    map utf8 (ascii <> wide) `shouldSatisfy` all (<= 210)
    map (TE.decodeUtf8' . TE.encodeUtf8) wide `shouldBe` map Right wide
  it "produces only valid names" $
    mapM_ (`shouldSatisfy` validChatName) $
      chatFileNames 12 ["", ".", "..", ".hidden", "x/y", T.replicate 400 "文", "\t"]
        <> [chatMediaName ChatImage 1 0 (Just "image/gif"), chatMediaName ChatVideo 1 0 Nothing]
  it "rejects names that could escape, hide or alias the directory" $
    mapM_
      (`shouldNotSatisfy` validChatName)
      ["", ".", "..", ".tmp-1", "a/b", "a\nb", "a\0b", T.replicate 256 "a"]
  where
    utf8 = BS.length . TE.encodeUtf8
