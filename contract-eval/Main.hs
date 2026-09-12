{-# LANGUAGE TemplateHaskell #-}

-- | Replay real requests through current production prompts and decoders.
-- No database, tools, repairs or publication: a failed first answer stays failed.
module Main (main) where

import Control.Monad (forM, forM_, unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Either (fromRight)
import Data.FileEmbed (embedFile)
import Data.IORef
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Data.Version (makeVersion)
import Effectful
import Effectful.Log (LogLevel (LogAttention), runLog)
import Max.Config (AppConfig (..), appConfigParser)
import Max.Effects.LLM
import Max.EpisodeStore (parseEpisodeCapture)
import Max.Historian (historianSystem)
import Max.HttpRuntime (newHttpRuntime)
import Max.Intent (classifierSystem, parseVerdict)
import Max.Log (withCompactLogger)
import Max.Memory.Maintenance (MaintenanceProposal, maintenanceSystem)
import Max.Task.Experience (experienceSystem, fingerprint, parseExperienceResponse, validateCapsule)
import Max.Task.Notice (noticeReviewPrompt, parseNoticeDecision)
import OptEnvConf (Parser, help, long, metavar, option, optional, reader, runParser, setting, str)
import System.Environment (getEnvironment)
import System.Exit (die, exitFailure)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)

data ContractOptions = ContractOptions {fixture :: !FilePath, report :: !FilePath, selected :: !(Maybe Text), rawReport :: !(Maybe FilePath)}

options :: Parser ContractOptions
options =
  ContractOptions
    <$> setting [option, reader str, long "contract-fixture", metavar "FILE", help "Private JSONL export from export-contract-inputs.sql"]
    <*> setting [option, reader str, long "contract-report", metavar "FILE", help "Public report; contains hashes and rates, never source text"]
    <*> optional (setting [option, reader str, long "contract", metavar "NAME", help "Select one inventoried contract"])
    <*> optional (setting [option, reader str, long "contract-raw-report", metavar "FILE", help "Private raw answers for evidence review; do not commit"])

data Input = Input {source :: !Text, profile :: !Text, model :: !Text, sourceCall :: !Int, sourceAt :: !Text, request :: !Value}

instance FromJSON Input where
  parseJSON = withObject "production request" $ \o -> Input <$> o .: "source" <*> o .: "profile" <*> o .: "model" <*> o .: "source_call_id" <*> o .: "source_at" <*> o .: "request"

contract :: Input -> Text
contract row | row.source `elem` ["task-notice-review", "task-progress-review"] = "task-notice"
contract row = row.source

-- Compile these bytes into the evaluator so an old executable cannot certify
-- modified source files just by reading the new working tree at runtime.
sourceBytes :: [(Text, ByteString)]
sourceBytes =
  [ ("src/Max/Historian.hs", $(embedFile "src/Max/Historian.hs")),
    ("src/Max/EpisodeStore.hs", $(embedFile "src/Max/EpisodeStore.hs")),
    ("src/Max/Task/Experience.hs", $(embedFile "src/Max/Task/Experience.hs")),
    ("src/Max/DB/Task/Experience.hs", $(embedFile "src/Max/DB/Task/Experience.hs")),
    ("src/Max/Memory/Maintenance.hs", $(embedFile "src/Max/Memory/Maintenance.hs")),
    ("src/Max/Intent.hs", $(embedFile "src/Max/Intent.hs")),
    ("src/Max/Task/Notice.hs", $(embedFile "src/Max/Task/Notice.hs")),
    ("src/Max/Task/NoticeReview.hs", $(embedFile "src/Max/Task/NoticeReview.hs"))
  ]

inventory :: Map.Map Text [Text]
inventory = either error id (eitherDecodeStrict' $(embedFile "contract-eval/contracts.json"))

hash :: ByteString -> Text
hash = TE.decodeUtf8 . B16.encode . SHA256.hash

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  environment <- getEnvironment
  unless (null [name | (name, _) <- environment, "MAX_LLM_" `T.isPrefixOf` T.pack name]) (die "unset local MAX_LLM_* overrides before replaying the production configuration")
  used <- newIORef Nothing
  (cfg, opts) <- runParser (makeVersion [0, 1, 0]) "max-contract-eval: first-response decode gate" ((,) <$> appConfigParser used <*> options)
  bytes <- LBS.readFile opts.fixture
  inputs <- traverse (either die pure . eitherDecode) (filter (not . LBS.null) (LBS.split 10 bytes))
  let names = maybe (Map.keys inventory) pure opts.selected
  unless (all (`Map.member` inventory) names) (die "unknown contract")
  packets <- forM names $ \name -> do
    let rows = filter ((== name) . contract) inputs
    unless (length rows >= 20 && length (nub (map (.sourceCall) rows)) >= 20) (die (T.unpack name <> ": requires at least 20 distinct real source calls"))
    forM rows $ \row -> do
      messages <- either (die . T.unpack) pure (currentMessages cfg row)
      pure (row, messages)
  calls <- newIORef []
  samples <- newIORef []
  started <- getCurrentTime
  runtime <- newHttpRuntime
  let writeReport complete = do
        done <- reverse <$> readIORef samples
        now <- getCurrentTime
        let summarized name =
              let rows = filter ((== String name) . field "contract") done
                  failures kind = length (filter ((== String kind) . field "outcome") rows)
                  n = length rows
               in object ["contract" .= name, "attempts" .= n, "decode_failures" .= failures "decode_failure", "provider_failures" .= failures "provider_failure", "decode_failure_rate" .= (if n == 0 then 1 else fromIntegral (failures "decode_failure") / fromIntegral n :: Double)]
        encodeFile opts.report (object ["version" .= (1 :: Int), "complete" .= complete, "started_at" .= started, "finished_at" .= now, "source_kind" .= ("production_llm_calls" :: Text), "fixture_sha256" .= hash (LBS.toStrict bytes), "source_hashes" .= Map.fromList [(path, hash body) | (path, body) <- sourceBytes], "first_responses_only" .= True, "contracts" .= map summarized names, "samples" .= done])
  writeReport False
  forM_ (concat packets) $ \(row, messages) -> do
    writeIORef calls []
    response <- withCompactLogger cfg.logColor Nothing $ \logger ->
      runEff
        . runLog "max-contract-eval" logger LogAttention
        . runLLM runtime (\_ _ _ -> pure ()) (\call -> modifyIORef' calls (call :)) cfg.llm
        $ chat (ChatCtx "contract-eval" Nothing Nothing Nothing (Just []) Nothing Nothing) row.profile messages []
    records <- reverse <$> readIORef calls
    let decoded = case response of
          Right (ContentResp answer) -> decodeContract (contract row) answer
          _ -> Left "provider_failure"
        outcome = either (const (case response of Right (ContentResp _) -> "decode_failure"; _ -> "provider_failure")) (const "decoded") decoded :: Text
        raw = case response of Right (ContentResp value) -> Just value; Right (InterruptedResp value _) -> Just value; _ -> Nothing
        actual = nub (map (.crModel) records)
        result =
          object
            [ "contract" .= contract row,
              "source_ref" .= fingerprint (toJSON row.sourceCall),
              "source_at" .= row.sourceAt,
              "input_fingerprint" .= fingerprint (toJSON messages),
              "prompt_fingerprint" .= fingerprint (toJSON [text | MsgSystem text <- messages]),
              "profile" .= row.profile,
              "expected_model" .= row.model,
              "actual_models" .= actual,
              "model_matches" .= (actual == [row.model]),
              "outcome" .= outcome,
              "semantic" .= fromRight Null decoded,
              "response_fingerprint" .= fmap (fingerprint . String) raw,
              "duration_ms" .= sum (map (.crDurationMs) records),
              "model_calls" .= length records,
              "usage" .= [object ["prompt_tokens" .= usage.usagePrompt, "completion_tokens" .= usage.usageCompletion, "cached_prompt_tokens" .= usage.usageCachedPrompt] | call <- records, Just usage <- [call.crUsage]]
            ]
    modifyIORef' samples (result :)
    forM_ opts.rawReport $ \path -> LBS.appendFile path (encode (object ["result" .= result, "source_call_id" .= row.sourceCall, "raw" .= raw, "decode_error" .= either Just (const Nothing) decoded]) <> "\n")
    writeReport False
    putStrLn (T.unpack (contract row <> ": " <> outcome))
  writeReport True
  done <- readIORef samples
  when (any (\row -> field "outcome" row /= String "decoded" || field "model_matches" row /= Bool True) done) exitFailure

field :: Key -> Value -> Value
field key (Object fields) = fromMaybe Null (KM.lookup key fields)
field _ _ = Null

-- Replace only the contract system message, preserving real user/assistant
-- inputs and the surrounding notice-review context. No hand-written fixtures.
currentMessages :: AppConfig -> Input -> Either Text [ChatMessage]
currentMessages cfg row = do
  original <- case row.request of
    Object fields ->
      either (Left . T.pack) Right $
        parseEither
          ( \o -> case KM.lookup "messages" o of
              Just values -> parseJSON values
              Nothing -> do
                instructions <- o .: "instructions"
                messages <- o .: "input"
                pure (MsgSystem instructions : messages)
          )
          fields
    _ -> Left "request is not an object"
  let prompt = case contract row of
        "historian" -> historianSystem
        "task-experience" -> experienceSystem
        "memory-maintenance" -> maintenanceSystem
        "intent" -> classifierSystem cfg.persona
        "task-notice" -> noticeReviewPrompt
        _ -> ""
      replaceFirst [] = Left "request has no contract system message"
      replaceFirst (MsgSystem _ : rest) = Right (MsgSystem prompt : rest)
      replaceFirst (message : rest) = (message :) <$> replaceFirst rest
  if contract row == "task-notice"
    then reverse <$> replaceFirst (reverse original)
    else replaceFirst original

decodeContract :: Text -> Text -> Either Text Value
decodeContract name raw = case name of
  "historian" -> either (Left . T.pack) (const (Right Null)) (parseEpisodeCapture raw)
  "task-experience" -> do
    candidate <- parseExperienceResponse raw
    pure $ case candidate of
      Nothing -> object ["abstained" .= True]
      Just capsule -> object ["abstained" .= False, "capsule_valid" .= either (const False) (const True) (validateCapsule capsule)]
  "memory-maintenance" -> either (Left . T.pack) (Right . toJSON . length) (eitherDecodeStrict' @[MaintenanceProposal] (TE.encodeUtf8 (T.strip raw)))
  "intent" -> maybe (Left "invalid intent verdict") (const (Right Null)) (parseVerdict raw)
  "task-notice" -> Null <$ parseNoticeDecision raw
  _ -> Left "unknown contract"
