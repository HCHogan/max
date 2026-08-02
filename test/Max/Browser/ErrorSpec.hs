module Max.Browser.ErrorSpec (spec) where

import Data.Aeson (object, (.=))
import Max.Browser.Error
  ( BrowserError (..),
    BrowserErrorKind (..),
    browserErrorFromMcp,
  )
import Max.MCP.Client (McpError (..), McpErrorKind (McpToolError))
import Test.Hspec

spec :: Spec
spec = describe "browserErrorFromMcp" $ do
  it "classifies a missing browse session from structured metadata" $ do
    let err = McpError McpToolError "provider wording may change" (metadata "session_gone")
    browserErrorFromMcp err
      `shouldBe` BrowserError BrowserSessionGone "provider wording may change"

  it "classifies a latched request guard from structured metadata" $ do
    let err = McpError McpToolError "any diagnostic text" (metadata "session_blocked")
    (.browserErrorKind) (browserErrorFromMcp err)
      `shouldBe` BrowserSessionBlocked

  it "does not infer recovery from unrecognised metadata or prose" $ do
    let err = McpError McpToolError "Session expired" (metadata "future_kind")
    (.browserErrorKind) (browserErrorFromMcp err)
      `shouldBe` BrowserCallFailed
  where
    metadata kind = Just (object ["camoufox/errorKind" .= (kind :: String)])
