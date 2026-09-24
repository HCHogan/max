module Max.Tools.BrowserSpec (spec) where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Effectful (liftIO, runEff)
import Max.Effects.Browser (BrowserOperation (..), runBrowser)
import Max.Effects.ToolOutput (newToolOutputQueue, runToolOutput)
import Max.Effects.Tools (Tool (..), ToolFault (..), ToolOutcome (..), ToolRunner (..))
import Max.Tools.Browser (browserToolsAt)
import Test.Hspec

-- | Run the browser tool once against a stub service; return the outcome and
-- the fields each browser operation received.
runBrowserTool :: Either Text Value -> Value -> IO (ToolOutcome, [(String, [(Text, Value)])])
runBrowserTool reply args = do
  seen <- newIORef []
  let record label fields = modifyIORef' seen (<> [(label, [(Key.toText key, value) | (key, value) <- fields])])
      handle = \case
        Navigate _ fields -> record "Navigate" fields >> pure reply
        Session method fields -> record (show method) fields >> pure reply
        ReadZhihu _ -> pure reply
  outcome <- runEff $ do
    queue <- newToolOutputQueue 0
    runToolOutput queue . runBrowser (liftIO . handle) $ case browserToolsAt False of
      Tool {toolRunner = OutcomeRunner run} : _ -> run args
      _ -> error "browser runner is not outcome-classified"
  (outcome,) <$> readIORef seen

-- | The full placeholder shape one model sends for every call.
placeholders :: Text -> [(Key, Value)] -> Value
placeholders action overrides =
  object $
    overrides
      <> [ key .= value
         | (key, value) <-
             [ ("action", String action),
               ("url", ""),
               ("selector", ""),
               ("frame", ""),
               ("query", ""),
               ("key", ""),
               ("text", ""),
               ("expression", ""),
               ("promptText", ""),
               ("value", Array mempty),
               ("deltaX", Number 0),
               ("deltaY", Number 0),
               ("mode", "text"),
               ("maxChars", Number 30000)
             ],
           key `notElem` map fst overrides
         ]

ok :: Either Text Value
ok = Right (object ["structuredContent" .= object ["text" .= ("page text" :: Text)]])

spec :: Spec
spec = describe "browser tool arguments and outcomes" $ do
  it "treats empty placeholders as absent instead of forwarding them" $ do
    (outcome, seen) <- runBrowserTool ok (placeholders "read" [])
    outcome `shouldSatisfy` \case ToolCommitted _ -> True; _ -> False
    case seen of
      [("SessionInspect", fields)] -> do
        lookup "mode" fields `shouldBe` Just "text"
        map fst fields `shouldNotContain` ["query"]
        map fst fields `shouldNotContain` ["selector"]
        map fst fields `shouldNotContain` ["frame"]
      other -> expectationFailure ("unexpected operations: " <> show other)

  it "forwards read offsets and keeps meaningful zero scrolls and empty fills" $ do
    (_, paged) <- runBrowserTool ok (placeholders "read" [("offset", Number 60000)])
    map (lookup "offset" . snd) paged `shouldBe` [Just (Number 60000)]
    (_, still) <- runBrowserTool ok (placeholders "scroll" [])
    [lookup "action" fields | (_, fields) <- still] `shouldBe` [Just (object ["type" .= ("scroll" :: Text)])]
    (_, sideways) <- runBrowserTool ok (placeholders "scroll" [("deltaX", Number 300)])
    [lookup "action" fields | (_, fields) <- sideways] `shouldBe` [Just (object ["type" .= ("scroll" :: Text), "deltaY" .= (0 :: Int), "deltaX" .= (300 :: Int)])]
    (_, cleared) <- runBrowserTool ok (placeholders "fill" [("selector", "#q")])
    [lookup "action" fields | (_, fields) <- cleared] `shouldBe` [Just (object ["type" .= ("fill" :: Text), "selector" .= ("#q" :: Text), "value" .= ("" :: Text)])]

  it "rejects missing arguments before any browser operation" $ do
    (outcome, seen) <- runBrowserTool ok (placeholders "open" [])
    seen `shouldBe` []
    case outcome of
      ToolRejected fault -> fault.tfMessage `shouldBe` "missing required arguments for browser action: url"
      other -> expectationFailure ("expected rejection, got " <> show other)
    (unknown, _) <- runBrowserTool ok (object ["action" .= ("teleport" :: Text)])
    unknown `shouldSatisfy` \case ToolRejected _ -> True; _ -> False

  it "classifies failed observations as retryable and failed interactions as uncertain" $ do
    (readFailure, _) <- runBrowserTool (Left "connection lost") (object ["action" .= ("read" :: Text)])
    readFailure `shouldSatisfy` \case ToolFailedBeforeEffect _ -> True; _ -> False
    (clickFailure, _) <- runBrowserTool (Left "connection lost") (object ["action" .= ("click" :: Text), "selector" .= ("#buy" :: Text)])
    clickFailure `shouldSatisfy` \case ToolOutcomeUnknown _ -> True; _ -> False
    (openFailure, _) <- runBrowserTool (Left "connection lost") (object ["action" .= ("open" :: Text), "url" .= ("https://example.test" :: Text)])
    openFailure `shouldSatisfy` \case ToolOutcomeUnknown _ -> True; _ -> False
