module Max.Browser.ViewSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Effectful (runEff)
import Max.Browser.Registry (browserScopeForTurn, newBrowserRegistry)
import Max.Browser.View
import Max.Effects.Agent (toolResultMessage)
import Max.Effects.LLM (ChatMessage (..), ToolCall (..))
import Max.Effects.ToolOutput (newToolOutputQueue, runToolOutput)
import Max.Effects.Tools (Tool (..))
import Max.HttpRuntime (newHttpRuntime)
import Max.Task.Types (TaskProfile (..), taskGrants)
import Max.Tools.Browser (browserToolsAt)
import Max.Turn.Types (AgentTurnId (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: Spec
spec = describe "browser view and surface" $ do
  it "bounds the entire text including noisy metadata, Unicode and elements" $ do
    let huge = T.replicate 90000 "界😀\n"
        element = object ["selector" .= huge, "name" .= huge, "role" .= huge]
        payload =
          object
            [ "structuredContent"
                .= object
                  [ "url" .= huge,
                    "title" .= huge,
                    "text" .= huge,
                    "elements" .= replicate 200 element,
                    "notes" .= replicate 50 huge,
                    "navigation" .= object ["complete" .= False]
                  ]
            ]
    forM_ [512, 1500, 6000, 30000] $ \size ->
      case browserView (BrowserBudget size 40) "snapshot" payload of
        String text -> T.length text `shouldSatisfy` (<= size)
        _ -> expectationFailure "expected compact text"

  it "projects partial navigation and changed URLs without leaking MCP IDs" $ do
    let payload =
          object
            [ "structuredContent"
                .= object
                  [ "url" .= ("https://example.test/new" :: String),
                    "title" .= ("Fixture" :: String),
                    "previousUrl" .= ("https://example.test/old" :: String),
                    "navigation" .= object ["complete" .= False],
                    "sessionId" .= ("secret-session" :: String),
                    "position" .= object ["x" .= (0 :: Int), "y" .= (40 :: Int), "width" .= (1280 :: Int), "height" .= (800 :: Int), "pageHeight" .= (5000 :: Int)],
                    "snapshot" .= object ["text" .= ("arrived content" :: String)],
                    "notes" .= ["blocked host tracker.invalid: DNS did not resolve" :: String]
                  ]
            ]
    case browserView (BrowserBudget 1500 20) "click" payload of
      String text -> do
        forM_ ["Outcome: click ok", "navigation incomplete", "page navigated from", "1280x800", "tracker.invalid", "arrived content"] $ \part ->
          text `shouldSatisfy` T.isInfixOf part
        text `shouldSatisfy` (not . T.isInfixOf "secret-session")
      _ -> expectationFailure "expected compact text"

  it "keeps the actual model message plain and bounded, including failure framing" $ do
    let args = object ["action" .= ("snapshot" :: String), "maxChars" .= (512 :: Int)]
        call = ToolCall "browser-call" "browser" args
        budget = browserBudget "snapshot" args
        raw = object ["structuredContent" .= object ["text" .= T.replicate 2000 "quotes\"\\\n界"]]
        projected = browserView budget "snapshot" raw
        unknown = browserFailureView budget "click" (T.replicate 2000 "lost response\n") <> " (outcome unknown; not retried)"
    case toolResultMessage call (Right projected) of
      MsgTool _ text -> do
        T.length text `shouldSatisfy` (<= 512)
        text `shouldSatisfy` T.isPrefixOf "Outcome:"
        text `shouldSatisfy` T.isInfixOf "\nPosition:"
      _ -> expectationFailure "expected tool message"
    case toolResultMessage call (Left unknown) of
      MsgTool _ text -> do
        T.length text `shouldSatisfy` (<= 512)
        text `shouldSatisfy` T.isSuffixOf "(outcome unknown; not retried)"
      _ -> expectationFailure "expected error tool message"

  it "requests screenshots for explicit requests, navigation or short content only" $ do
    let payload fields = object ["structuredContent" .= object fields]
        long = "text" .= T.replicate 200 "x"
    browserNeedsScreenshot "click" (payload [long]) `shouldBe` False
    browserNeedsScreenshot "screenshot" (payload [long]) `shouldBe` True
    browserNeedsScreenshot "click" (payload [long, "previousUrl" .= ("https://before.test" :: String)]) `shouldBe` True
    browserNeedsScreenshot "snapshot" (payload ["text" .= ("short" :: String)]) `shouldBe` True

  it "grants exactly the browser runners and retires nonexistent legacy tools" $ do
    reg <- newHttpRuntime >>= newBrowserRegistry
    let runners = browserToolsAt (browserScopeForTurn (GroupId 1) (AgentTurnId 1)) reg Nothing
        names = sort [runner.toolName | runner <- runners]
        candidates = Map.fromList [(name, "grant") | name <- names <> ["browser_back", "browser_screenshot", "browser_navigate", "browser_click"]]
    names `shouldBe` ["browser", "view_zhihu"]
    Map.keys (taskGrants Browser candidates) `shouldBe` names
    taskGrants Research candidates `shouldBe` Map.empty
    case runners of
      browser : _ ->
        runEff (do queue <- newToolOutputQueue 0; runToolOutput queue (browser.toolRun (object ["action" .= ("evaluate" :: String), "expression" .= ("1+1" :: String)])))
          >>= (`shouldSatisfy` either (T.isInfixOf "requires a browser task") (const False))
      [] -> expectationFailure "missing browser runner"
