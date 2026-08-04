module Max.IR.DigestSpec (spec) where

import Data.Aeson (Value (Object))
import Data.Aeson.KeyMap qualified as KM
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.IR
import Max.IR.Digest
import Max.Platform.Types (NativeUserId (..), PrincipalIdentityId (..))
import Test.Hspec

imgMeta :: Maybe Int -> MediaMeta
imgMeta size =
  MediaMeta
    { kind = MImage,
      mime = Nothing,
      sizeBytes = fromIntegral <$> size,
      name = Nothing,
      description = Just "两只猫",
      raw = Nothing
    }

spec :: Spec
spec = describe "log digest" $ do
  it "digests a canonical body as shapes and references" $ do
    let sha = T.replicate 64 "a"
        body =
          Body
            [ NText "你好",
              NMention (MentionIdentity (PrincipalIdentityId 7)) "张三",
              NMedia (mediaBlobRef sha) (imgMeta (Just 186368))
            ] ::
            Body 'Canonical
    digestLine body
      `shouldBe` "text(6B)+mention(pid:7)+image(blob:aaaaaaaa…,182.0KB)"

  it "digests the lowered phase — exactly what went to the wire" $ do
    let body =
          Body
            [ NMention (NativeUserId "123456") "张三",
              NMedia (ResolvedBytes (TE.encodeUtf8 "abc")) (imgMeta Nothing)
            ] ::
            Body 'Lowered
    digestLine body `shouldBe` "mention(@123456)+image(bytes:3B)"

  it "digests the model-parsed phase" $ do
    let body =
          Body [NMedia (RefSticker 42) (imgMeta Nothing) {kind = MSticker}] ::
            Body 'ModelParsed
    digestLine body `shouldBe` "sticker(sticker#42)"

  it "carries sizes and counts, never payloads" $ do
    let secret = T.replicate 100 "机密"
        body = Body [NText secret] :: Body 'Canonical
        line = digestLine body
    line `shouldBe` "text(600B)"
    line `shouldSatisfy` (not . T.isInfixOf "机密")

  it "bounds the whole line" $ do
    let body = Body (replicate 100 (NText "0123456789")) :: Body 'Canonical
    T.length (digestLine body) `shouldSatisfy` (<= 400)

  it "exposes stable structured keys" $ do
    let body = Body [NText "你好", NText "again"] :: Body 'Canonical
    case digest body of
      Object o -> do
        KM.lookup "nodes" o `shouldSatisfy` (/= Nothing)
        KM.lookup "text_bytes" o `shouldSatisfy` (/= Nothing)
        KM.lookup "digest" o `shouldSatisfy` (/= Nothing)
      other -> expectationFailure ("digest was not an object: " <> show other)
