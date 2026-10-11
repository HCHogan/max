module Max.HookSpec (spec) where

import Control.Concurrent.Async (concurrently)
import Data.Aeson
import Data.Either (isLeft)
import Data.Text (Text)
import Effectful (runEff)
import Max.Hook.Runtime
import Max.Hook.Types
import Test.Hspec

spec :: Spec
spec = beforeAll_ warmHookRuntime $ describe "message.inbound hooks" $ do
  let make code = HookDefinition "test" 1 code (object ["blocked_principals" .= ([123] :: [Int])]) True
      event = object ["sender_principal" .= (123 :: Int), "text" .= ("消息😀" :: Text)]
      run code = runEff (runHook (make code) event)
  it "executes a configured predicate with canonical identity and Unicode" $ do
    result <- run "return {action: args.config.blocked_principals.includes(args.event.sender_principal) ? 'ignore' : 'pass', reason: args.event.text};"
    result.outcome `shouldBe` "ignore"
    result.reason `shouldBe` Just "消息😀"
    result.elapsedMs `shouldSatisfy` (> 0)
  it "passes ordinary messages and validates the closed output contract" $ do
    (.outcome) <$> run "return {action:'pass'};" `shouldReturn` "pass"
    mapM_
      (\code -> (.outcome) <$> run code `shouldReturn` "error")
      ["return null;", "return {action:'send'};", "return {action:'pass',source:'spoof'};", "return {action:'ignore',reason:'\\0'};"]
  it "bounds runaway code and rejects host effects" $ do
    mapM_
      (\code -> (.outcome) <$> run code `shouldReturn` "error")
      ["while(true) {}", "await max.sleep(1); return {action:'pass'};", "await tools.set_hook({});", "await fetch('https://example.com');", "return {action:new Date()};"]
  it "compiles without running user code, and rejects syntax errors" $ do
    runEff (validateSource "while(true) {}") `shouldReturn` Right ()
    runEff (validateSource "return {;") >>= (`shouldSatisfy` isLeft)
  it "caches code without sharing globals, mutable config or interrupts between guests" $ do
    (.outcome) <$> run "globalThis.leaked=true; args.config.blocked_principals=[]; return {action:'pass'};" `shouldReturn` "pass"
    (.outcome) <$> run "return {action:globalThis.leaked || args.config.blocked_principals.length!==1 ? 'ignore':'pass'};" `shouldReturn` "pass"
    (bad, good) <- concurrently (run "while(true) {}") (run "return {action:'pass'};")
    bad.outcome `shouldBe` "error"
    good.outcome `shouldBe` "pass"
  it "patches only supplied fields and replaces config, including null" $ do
    let original = make "return {action:'pass'};"
        patch = HookPatch "test" 1 Nothing Nothing (Just Null) (Just False)
    applyHookPatch patch (Just original) `shouldBe` Right original {revision = 2, config = Null, enabled = False}
    applyHookPatch patch {hpExpected = 0} (Just original) `shouldSatisfy` isLeft
  it "rejects cross-scope arguments, unsupported events and ambiguous test input" $ do
    parseHookPatch (object ["name" .= ("test" :: Text), "expected_revision" .= (0 :: Int), "source" .= ("return {};" :: Text), "group_id" .= (1 :: Int)]) `shouldSatisfy` isLeft
    parseHookPatch (object ["name" .= ("test" :: Text), "expected_revision" .= (0 :: Int), "source" .= ("return {};" :: Text), "event" .= ("message.outbound" :: Text)]) `shouldSatisfy` isLeft
    parseHookQuery (object ["view" .= ("test" :: Text), "source" .= ("return {};" :: Text), "message_id" .= (1 :: Int), "sample" .= event]) `shouldSatisfy` isLeft
