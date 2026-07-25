{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Replay a fixture of intent-classification cases against a live LLM
-- profile and report trigger/kind accuracy — the regression harness
-- for tuning the classifier prompt or swapping its model.
--
-- Fixture: JSONL, one case per line:
--
-- > {"context": ["[07-22 14:01] 小明: …"], "new": ["[07-22 14:03] 小明: max帮我看看"],
-- >  "expect_trigger": true, "expect_kind": "called", "note": "无@叫名"}
--
-- Bootstrap one from production logs with
-- @scripts/extract-intent-fixture.sh@, then hand-check the labels.
-- Config (LLM profiles, persona) loads exactly like max-bot: same
-- yaml/env/flags, so run it next to the bot's max.yaml.
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.ByteString.Char8 qualified as BS8
import Data.Char (isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Version (makeVersion)
import Effectful
import Effectful.Log (LogLevel (LogAttention), runLog)
import Effectful.Wreq (runWreq)
import Max.Log (withCompactLogger)
import Max.Config (AppConfig (..), appConfigParser)
import Max.Effects.LLM (runLLM)
import Max.Intent (IntentConfig (..), IntentVerdict (..), classifyOnce, kindText)
import OptEnvConf
import System.Exit (die, exitFailure)
import Text.Printf (printf)

data EvalOpts = EvalOpts
  { eoFixture :: !FilePath,
    eoProfile :: !(Maybe Text),
    eoMinAccuracy :: !Double
  }

evalOptsParser :: Parser EvalOpts
evalOptsParser = do
  eoFixture <-
    setting
      [ help "JSONL fixture of intent cases (see eval/README.md)",
        reader str,
        option,
        long "fixture",
        env "MAX_EVAL_FIXTURE",
        metavar "FILE",
        value "eval/fixtures/intent.jsonl"
      ]
  eoProfile <-
    optional $
      setting
        [ help "LLM profile to evaluate (default: intent.profile from config)",
          reader str,
          option,
          long "eval-profile",
          metavar "NAME"
        ]
  eoMinAccuracy <-
    setting
      [ help "Exit non-zero when trigger accuracy falls below this (0..1)",
        reader auto,
        option,
        long "min-accuracy",
        metavar "F",
        value 0
      ]
  pure EvalOpts {..}

-- | One fixture line.  @expect_kind@ is only checked on cases where
-- both sides agree the trigger fired.
data Case = Case
  { cContext :: ![Text],
    cNew :: ![Text],
    cExpectTrigger :: !Bool,
    cExpectKind :: !(Maybe Text),
    cNote :: !(Maybe Text)
  }

instance FromJSON Case where
  parseJSON = withObject "case" $ \o ->
    Case
      <$> (fromMaybe [] <$> o .:? "context")
      <*> o .: "new"
      <*> o .: "expect_trigger"
      <*> o .:? "expect_kind"
      <*> o .:? "note"

main :: IO ()
main = do
  (cfg, opts) <-
    runParser
      (makeVersion [0, 1, 0])
      "max-intent-eval — replay intent-classifier fixtures against a live profile"
      ((,) <$> appConfigParser <*> evalOptsParser)
  profile <- case opts.eoProfile <|> ((.icProfile) <$> cfg.intent) of
    Just p -> pure p
    Nothing -> die "no profile: pass --eval-profile or configure intent.profile"

  raw <- BS8.readFile opts.eoFixture
  let numbered =
        [ (i, eitherDecodeStrict' ln :: Either String Case)
          | (i :: Int, ln) <- zip [1 ..] (BS8.lines raw),
            not (BS8.all isSpace ln)
        ]
      bad = [(i, e) | (i, Left e) <- numbered]
      cases = [(i, c) | (i, Right c) <- numbered]
  unless (null bad) $
    die $
      unlines $
        "fixture has unparseable lines:"
          : [printf "  line %d: %s" i e | (i, e) <- bad]
  unless (not (null cases)) $ die "fixture is empty"

  -- LogAttention: per-case verdict logs stay quiet, real errors
  -- (HTTP failures, unparseable verdicts) still surface.
  results <- withCompactLogger cfg.logColor $ \logger ->
    runEff . runLog "max-intent-eval" logger LogAttention . runWreq . runLLM cfg.llm $
      traverse
        (\(i, c) -> (,) (i, c) <$> classifyOnce profile cfg.persona c.cContext c.cNew)
        cases

  let infraFails = [(i, c) | ((i, c), Nothing) <- results]
      judged = [(i, c, v) | ((i, c), Just v) <- results]
      falsePos = [x | x@(_, c, v) <- judged, v.ivTrigger, not c.cExpectTrigger]
      falseNeg = [x | x@(_, c, v) <- judged, not v.ivTrigger, c.cExpectTrigger]
      hits = length judged - length falsePos - length falseNeg
      kindChecked =
        [ (i, c, v, ek)
          | (i, c, v) <- judged,
            v.ivTrigger,
            c.cExpectTrigger,
            Just ek <- [c.cExpectKind]
        ]
      kindMisses = [x | x@(_, _, v, ek) <- kindChecked, ek /= kindText v.ivKind]
      accuracy :: Double
      accuracy = fromIntegral hits / fromIntegral (max 1 (length judged))

      showMiss (i, c, v) =
        printf
          "  line %d: expected %s, got %s (reason: %s)%s"
          i
          (show c.cExpectTrigger)
          (show v.ivTrigger)
          (T.unpack (fromMaybe "-" v.ivReason))
          (maybe "" ((" — " <>) . T.unpack) c.cNote)

  printf "profile: %s\n" (T.unpack profile)
  printf "cases: %d judged, %d classifier failures\n" (length judged) (length infraFails)
  printf "trigger accuracy: %d/%d (%.1f%%)\n" hits (length judged) (accuracy * 100)
  unless (null falsePos) $ do
    printf "false positives (%d):\n" (length falsePos)
    mapM_ (putStrLn . showMiss) falsePos
  unless (null falseNeg) $ do
    printf "false negatives (%d):\n" (length falseNeg)
    mapM_ (putStrLn . showMiss) falseNeg
  unless (null kindChecked) $
    printf
      "kind accuracy (both-triggered cases with expect_kind): %d/%d\n"
      (length kindChecked - length kindMisses)
      (length kindChecked)
  unless (null kindMisses) $
    mapM_
      ( \(i, _, v, ek) ->
          printf "  line %d: expected kind %s, got %s\n" i (T.unpack ek) (T.unpack (kindText v.ivKind))
      )
      kindMisses
  unless (null infraFails) $ do
    printf "classifier failures (%d):\n" (length infraFails)
    mapM_ (\(i, _) -> printf "  line %d: no verdict (see log lines above)\n" (i :: Int)) infraFails

  unless (accuracy >= opts.eoMinAccuracy) $ do
    printf "FAIL: accuracy %.3f below --min-accuracy %.3f\n" accuracy opts.eoMinAccuracy
    exitFailure
