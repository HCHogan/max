module Max.Browser.VaultSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Max.Browser.Vault
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import Test.Hspec

spec :: Spec
spec = describe "browser checkpoint vault" $ do
  it "encrypts state and authenticates its workspace identity" $ do
    vault <- newBrowserVault
    sealed <- sealBrowserState vault "task/1" sample
    sealed `shouldSatisfy` (not . T.isInfixOf "fixture-cookie")
    openBrowserState vault "task/1" sealed `shouldBe` Right sample
    openBrowserState vault "task/2" sealed `shouldSatisfy` isLeft
    openBrowserState vault "task/1" ("!!!!" <> sealed) `shouldSatisfy` isLeft

  it "uses fresh nonces and rejects the wrong encryption key" $ do
    first <- newBrowserVault
    second <- newBrowserVault
    saved <- sealBrowserState first "task/1" sample
    again <- sealBrowserState first "task/1" sample
    saved `shouldNotBe` again
    openBrowserState second "task/1" saved `shouldSatisfy` isLeft

  it "persists the key across restart but rejects permissive key files" $
    withSystemTempDirectory "max-browser-vault" $ \directory -> do
      let path = directory </> "state.key"
      original <- loadBrowserVault path
      sealed <- sealBrowserState original "task/1" sample
      restarted <- loadBrowserVault path
      openBrowserState restarted "task/1" sealed `shouldBe` Right sample
      setFileMode path 0o644
      loadBrowserVault path `shouldThrow` anyIOException

sample :: Value
sample = object ["cookie" .= ("fixture-cookie" :: Text)]
