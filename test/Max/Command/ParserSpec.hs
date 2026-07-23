module Max.Command.ParserSpec (spec) where

import Data.Text (Text)
import Max.Command.Parser (parseCommand)
import Max.Command.Types (Command (..), UnpinTarget (..))
import Test.Hspec

-- | Convenience: assert that an input parses to a specific 'Command'.
parsesTo :: Text -> Command -> Expectation
parsesTo input expected = parseCommand input `shouldBe` Right (Just expected)

-- | Convenience: assert that an input is NOT classified as a command
-- (passes through to the LLM path).
notACommand :: Text -> Expectation
notACommand input = parseCommand input `shouldBe` Right Nothing

spec :: Spec
spec = do
  describe "looksLikeCommand pre-check" $ do
    it "rejects plain text" $ notACommand "hello"
    it "rejects empty string" $ notACommand ""
    it "rejects bang-only" $ notACommand "!"
    it "rejects bang-non-letter" $ notACommand "!1abc"
    it "rejects Chinese exclamation" $ notACommand "！help"
    it "tolerates leading spaces" $ "  !help" `parsesTo` Help Nothing

  describe "!help" $ do
    it "no topic" $ "!help" `parsesTo` Help Nothing
    it "with topic" $ "!help model" `parsesTo` Help (Just "model")

  describe "!model" $ do
    it "bare → show" $ "!model" `parsesTo` ModelShow
    it "list" $ "!model list" `parsesTo` ModelList
    it "set" $ "!model deepseek-flash" `parsesTo` ModelSet "deepseek-flash"
    it "two args falls through to Unknown" $
      case parseCommand "!model foo bar" of
        Right (Just (Unknown "model" _)) -> pure ()
        other -> expectationFailure $ "expected Unknown model, got: " <> show other

  describe "!grant / !revoke / !perms" $ do
    it "grant with canonical mention token" $
      "!grant [@#223344556] persona" `parsesTo` Grant 223344556 "persona" False False
    it "grant with bare qq and flags" $
      "!grant 223344556 model --deny --global" `parsesTo` Grant 223344556 "model" True True
    it "revoke with @qq form" $
      "!revoke @223344556 persona" `parsesTo` Revoke 223344556 "persona" False
    it "perms defaults to self" $ "!perms" `parsesTo` Perms Nothing
    it "perms with target" $ "!perms [@#10001]" `parsesTo` Perms (Just 10001)
    it "non-numeric target falls through to Unknown" $
      case parseCommand "!grant 阿飞 persona" of
        Right (Just (Unknown "grant" _)) -> pure ()
        other -> expectationFailure $ "expected Unknown grant, got: " <> show other

  describe "!persona" $ do
    it "show" $ "!persona" `parsesTo` PersonaShow
    it "clear" $ "!persona clear" `parsesTo` PersonaClear
    it "set joins words" $ "!persona 你 是 一只 猫" `parsesTo` PersonaSet "你 是 一只 猫"
    it "set with quotes" $ "!persona \"hello world\"" `parsesTo` PersonaSet "hello world"

  describe "!proactive" $ do
    it "bare → status" $ "!proactive" `parsesTo` ProactiveStatus
    it "on" $ "!proactive on" `parsesTo` ProactiveSet (Just True)
    it "off" $ "!proactive off" `parsesTo` ProactiveSet (Just False)
    it "default" $ "!proactive default" `parsesTo` ProactiveSet Nothing
    it "garbage falls through to Unknown" $
      case parseCommand "!proactive maybe" of
        Right (Just (Unknown "proactive" _)) -> pure ()
        other -> expectationFailure $ "expected Unknown proactive, got: " <> show other

  describe "!clear / !unclear" $ do
    it "plain clear" $ "!clear" `parsesTo` Clear
    it "clear --all" $ "!clear --all" `parsesTo` ClearAll
    it "unclear" $ "!unclear" `parsesTo` Unclear

  describe "!pin / !unpin / !pins" $ do
    it "pin bare → reply target" $ "!pin" `parsesTo` Pin Nothing
    it "pin with id" $ "!pin 42" `parsesTo` Pin (Just 42)
    it "pin with negative id" $ "!pin -1" `parsesTo` Pin (Just (-1))
    it "pin with garbage falls through" $
      case parseCommand "!pin xyz" of
        Right (Just (Unknown "pin" _)) -> pure ()
        other -> expectationFailure $ "expected Unknown pin, got: " <> show other
    it "unpin bare → reply target" $ "!unpin" `parsesTo` Unpin UnpinReply
    it "unpin all" $ "!unpin all" `parsesTo` Unpin UnpinAll
    it "unpin with id" $ "!unpin 42" `parsesTo` Unpin (UnpinOne 42)
    it "pins" $ "!pins" `parsesTo` Pins

  describe "!btw" $ do
    it "joins words" $ "!btw 别忘了 加 typeclass" `parsesTo` Btw "别忘了 加 typeclass"
    it "empty body still works" $ "!btw" `parsesTo` Btw ""

  describe "!ps / !kill" $ do
    it "ps local" $ "!ps" `parsesTo` PsLocal
    it "ps all" $ "!ps --all" `parsesTo` PsAll
    it "kill" $ "!kill T-1" `parsesTo` Kill "T-1"
    it "kill all" $ "!kill --all" `parsesTo` KillAll

  describe "! shell escape" $ do
    it "bang-space → Shell, no packages" $ "! ls -al" `parsesTo` Shell [] "ls -al"
    it "keeps pipes and flags verbatim" $
      "! cat a | grep -n x" `parsesTo` Shell [] "cat a | grep -n x"
    it "tolerates extra spaces after the bang" $ "!   pwd" `parsesTo` Shell [] "pwd"
    it "tolerates leading spaces before the bang" $ "  ! whoami" `parsesTo` Shell [] "whoami"
    it "bang-space with empty body is not a command" $ notACommand "!   "
    it "bang-verb (no space) stays structured" $ "!pins" `parsesTo` Pins
    it "preserves internal newlines (multi-line)" $
      "! ls -al\ncd foo\ncat bar" `parsesTo` Shell [] "ls -al\ncd foo\ncat bar"
    it "peels leading +pkg tokens, single line" $
      "! +python3 +ffmpeg ffmpeg -i a.mp4 out.gif"
        `parsesTo` Shell ["python3", "ffmpeg"] "ffmpeg -i a.mp4 out.gif"
    it "peels +pkg across the newline before the command" $
      "! +python3 +requests\npython3 script.py"
        `parsesTo` Shell ["python3", "requests"] "python3 script.py"
    it "does not treat a mid-command + as a package" $
      "! echo 1 + 2" `parsesTo` Shell [] "echo 1 + 2"
    it "ignores a lone + " $ "! + ls" `parsesTo` Shell [] "ls"

  describe "!memory" $ do
    it "bare memory → list" $ "!memory" `parsesTo` MemoryList
    it "memory rm with id" $ "!memory rm 42" `parsesTo` MemoryRm 42
    it "memory rm with junk id → Unknown" $
      case parseCommand "!memory rm abc" of
        Right (Just (Unknown "memory" _)) -> pure ()
        other -> expectationFailure $ "expected Unknown memory, got: " <> show other

  describe "!version" $
    it "parses" $ "!version" `parsesTo` Version

  describe "unknown verbs" $ do
    it "fall through to Unknown with the raw verb" $
      case parseCommand "!nope foo bar" of
        Right (Just (Unknown "nope" _)) -> pure ()
        other -> expectationFailure $ "expected Unknown nope, got: " <> show other
