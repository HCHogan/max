module Max.Effects.EmbeddingSpec (spec) where

import Effectful (runEff)
import Max.Effects.Embedding
import Max.Embedding (EmbeddingRecord (..))
import Test.Hspec

spec :: Spec
spec = describe "Embedding effect" $ do
  it "injects model space and validated records without exposing a client" $ do
    let space = EmbeddingSpace "fake-v2"
        record = EmbeddingRecord "fake-v2" 3 "hash" "[1,2,3]"
    result <-
      runEff . runEmbeddingWith (Just space) (\texts -> pure (Right [record | _ <- texts])) $
        (,) <$> embeddingSpace <*> embedBatch ["hello"]
    result `shouldBe` (Just space, Right [record])

  it "lets tests classify transport and shape failures" $ do
    let fault = EmbeddingFault EmbeddingInvalidShape "mixed dimensions"
    result <-
      runEff . runEmbeddingWith (Just (EmbeddingSpace "fake")) (\_ -> pure (Left fault)) $
        embedBatch ["hello"]
    result `shouldBe` Left fault
    renderEmbeddingFault fault `shouldBe` "invalid-shape: mixed dimensions"

  it "makes model and dimension cutovers observable to callers" $ do
    let oldRecord = EmbeddingRecord "embed-v1" 3 "old-hash" "[1,2,3]"
        newRecord = EmbeddingRecord "embed-v2" 5 "new-hash" "[1,2,3,4,5]"
        runOne space record =
          runEff . runEmbeddingWith (Just space) (\_ -> pure (Right [record])) $
            (,) <$> embeddingSpace <*> embedBatch ["same source"]
    old <- runOne (EmbeddingSpace "embed-v1") oldRecord
    new <- runOne (EmbeddingSpace "embed-v2") newRecord
    old `shouldBe` (Just (EmbeddingSpace "embed-v1"), Right [oldRecord])
    new `shouldBe` (Just (EmbeddingSpace "embed-v2"), Right [newRecord])
    oldRecord.erDimensions `shouldNotBe` newRecord.erDimensions

  it "can inject a timeout-shaped transport failure without network IO" $ do
    let timeoutFault = EmbeddingFault EmbeddingTransport "request timed out"
    result <-
      runEff . runEmbeddingWith (Just (EmbeddingSpace "fake")) (\_ -> pure (Left timeoutFault)) $
        embedBatch ["hello"]
    result `shouldBe` Left timeoutFault
