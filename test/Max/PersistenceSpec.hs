module Max.PersistenceSpec (spec) where

import Effectful (Eff, IOE, runEff)
import Effectful.Reader.Dynamic (Reader, runReader)
import Max.Persistence (PersistMode (..), isEphemeral, withEphemeral)
import Test.Hspec

-- | Run an effectful action with a given initial 'PersistMode',
-- returning its result in 'IO'.  Keeps each spec a one-liner.
withMode :: PersistMode -> Eff '[Reader PersistMode, IOE] a -> IO a
withMode m action = runEff (runReader m action)

spec :: Spec
spec = describe "Max.Persistence" $ do
  it "isEphemeral defaults to False under Persisted" $ do
    e <- withMode Persisted isEphemeral
    e `shouldBe` False

  it "isEphemeral is True directly under Volatile" $ do
    e <- withMode Volatile isEphemeral
    e `shouldBe` True

  it "withEphemeral flips Persisted → True inside the scope" $ do
    inside <- withMode Persisted (withEphemeral isEphemeral)
    inside `shouldBe` True

  it "withEphemeral restores the outer mode after the scope exits" $ do
    (inside, after) <- withMode Persisted $ do
      i <- withEphemeral isEphemeral
      a <- isEphemeral
      pure (i, a)
    inside `shouldBe` True
    after `shouldBe` False

  it "withEphemeral nested under itself is still ephemeral" $ do
    deep <- withMode Persisted $ withEphemeral (withEphemeral isEphemeral)
    deep `shouldBe` True
