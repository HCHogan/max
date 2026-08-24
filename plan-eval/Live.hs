{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE RecordWildCards #-}

-- | Ask real models to write the plan dialect, and judge what comes back.
--
-- The offline gate (@max-plan-eval@) measures the kernel against fixtures a
-- human wrote.  This measures models against the kernel, which is the question
-- ADR 002 step 7 actually turns on: not "is the dialect sound" but "can the
-- models we would ship with produce admissible plans in it".
--
-- Every candidate goes through "Harness", the same environment the offline gate
-- judges in, so a difference between the two runs is a difference in the
-- candidates and not in the setup.
--
-- Three things are counted separately on purpose, because collapsing them
-- would hide which one is worth fixing:
--
--   * __Transport failures and empty replies__ are excluded from every rate.
--     A timed-out request says nothing about a model's grasp of the grammar,
--     and neither does a 200 with no content — which in practice means a
--     reasoning model spent its whole @max_tokens@ thinking.  Counting those
--     as unparsed understates a model by exactly the tasks it found hardest,
--     which is the worst possible direction for the bias to run.
--   * __A code fence, or a tool call, is an instruction-following failure__,
--     not a dialect failure.  The prompt asks for a bare plan.  The fence is
--     counted, then stripped, and the body judged on its own merits — silently
--     stripping it first would merge two very different problems.
--   * __Rejection classes are reported per model.__  "Which frontier does this
--     model keep walking into" is the actionable number; a single pass rate is
--     not.
--
-- Config (LLM profiles) loads exactly like max-bot: same yaml/env/flags, so run
-- it next to the bot's max.yaml.
module Main (main) where

import Control.Monad (unless, when)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeStrict', encode, object, withObject, (.:), (.=))
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text.Encoding qualified as TE
import Data.Char (isSpace)
import Data.IORef (newIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Paths_max (version)
import Effectful
import Effectful.Log (LogLevel (LogAttention), runLog)
import Harness
import Max.Config (AppConfig (..), appConfigParser)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (for_)
import Max.Effects.LLM (ChatCtx (..), ChatMessage (..), ChatResponse (..), LLM, ToolCall (..), ToolSpec (..), chat, runLLM)
import Max.Plan.Brief (subgoalBrief)
import Max.Plan.Drive (Dispatchable (..))
import Max.Plan.Reconcile (Desired (..))
import Max.Plan.Schema (PlanSchema (..), SchemaField (..), checkValue, jsonSchemaOf, schemaErrorText)
import Max.HttpRuntime (newHttpRuntime)
import Max.Log (withCompactLogger)
import Max.Plan.Prompt (frontPrompt)
import Max.Plan.Types (Binder (..), Goal (..), NodeId (..))
import Max.Plan.Validate (ValidationEnv (..))
import OptEnvConf
import System.Exit (die, exitFailure)
import Text.Printf (printf)

data LiveOpts = LiveOpts
  { loProfiles :: !Text,
    loTasks :: !FilePath,
    loRepeat :: !Int,
    loOut :: !(Maybe FilePath),
    loMinAdmit :: !Double,
    loDryRun :: !Bool,
    -- | Ask the other half of the question: not "can a model write a fork" but
    -- "can the child a fork opens hand a value back". ADR 007 §11's return
    -- tool is the newest surface in the design and the one with no evidence.
    loChildren :: !Bool
  }

liveOptsParser :: Parser LiveOpts
liveOptsParser = do
  loProfiles <-
    setting
      [ help "Comma-separated LLM profiles to compare",
        reader str,
        option,
        long "profiles",
        env "MAX_PLAN_LIVE_PROFILES",
        metavar "A,B,C"
      ]
  loTasks <-
    setting
      [ help "JSONL of tasks to elaborate (see plan-eval/README.md)",
        reader str,
        option,
        long "tasks",
        metavar "FILE",
        value "plan-eval/fixtures/tasks.jsonl"
      ]
  loRepeat <-
    setting
      [ help "Attempts per (profile, task).  A success rate from one sample is noise",
        reader auto,
        option,
        long "repeat",
        metavar "N",
        value 1
      ]
  loOut <-
    optional $
      setting
        [ help "Write every candidate as JSONL — the raw material for new fixtures",
          reader str,
          option,
          long "out",
          metavar "FILE"
        ]
  loMinAdmit <-
    setting
      [ help "Exit non-zero when the best profile's admission rate falls below this (0..1)",
        reader auto,
        option,
        long "min-admit",
        metavar "F",
        value 0
      ]
  loDryRun <-
    setting
      [ help "Print the prompt and the task list, then stop.  Makes no requests",
        switch True,
        long "dry-run",
        value False
      ]
  loChildren <-
    setting
      [ help "Ask the child half instead: hand over one subgoal and see whether a value comes back",
        switch True,
        long "children",
        value False
      ]
  pure LiveOpts {..}

-- | One thing to ask for.  The name is for the report; the task becomes the
-- goal's objective, so the model reads it in the same place the kernel will
-- check against.
data Task = Task
  { tkName :: !Text,
    tkTask :: !Text
  }

instance FromJSON Task where
  parseJSON = withObject "task" $ \o -> Task <$> o .: "name" <*> o .: "task"

-- | What one attempt produced.
data Candidate = Candidate
  { cdProfile :: !Text,
    cdTask :: !Task,
    cdAttempt :: !Int,
    cdAttemptOutcome :: !Attempt
  }

-- | Three genuinely different things, kept apart so a rate cannot silently
-- average them together.
data Attempt
  = -- | The request failed.  Says nothing about the model.
    Failed !Text
  | -- | A reply arrived with nothing usable in it.  Also says nothing about
    -- the model's grasp of the dialect — only that it never got to writing any.
    Silent
  | Answered !Reply

data Reply = Reply
  { rpRaw :: !Text,
    -- | The text actually judged: the fence body, or the reply unchanged.
    rpSource :: !Text,
    rpFenced :: !Bool,
    -- | The model reached for a tool instead of writing a plan.
    rpToolCalled :: !Bool,
    rpJudged :: !Judged
  }

-- | The goal a model is handed, with the task as its objective.
envFor :: Task -> ValidationEnv
envFor task = planEnv {venGoal = planEnv.venGoal {goalObjective = task.tkTask}}

-- | A fixed, short user turn.  The task itself lives in the goal, so it is
-- stated once; a second copy here would let the two drift apart.
userTurn :: Text
userTurn = "按上面的「本轮目标」写出计划。"

main :: IO ()
main = do
  usedRef <- newIORef Nothing
  (cfg, opts) <-
    runParser
      version
      "max-plan-live — ask real models to write the plan dialect"
      ((,) <$> appConfigParser usedRef <*> liveOptsParser)

  let profiles = [T.strip p | p <- T.splitOn "," opts.loProfiles, not (T.null (T.strip p))]
  when (null profiles) $ die "no profiles: pass --profiles a,b,c"
  when (opts.loRepeat < 1) $ die "--repeat must be at least 1"

  raw <- BS8.readFile opts.loTasks
  let numbered =
        [ (i, eitherDecodeStrict' ln :: Either String Task)
          | (i :: Int, ln) <- zip [1 ..] (BS8.lines raw),
            not (BS8.all isSpace ln)
        ]
      bad = [(i, e) | (i, Left e) <- numbered]
      tasks = [t | (_, Right t) <- numbered]
  unless (null bad) $
    die $
      unlines $
        "task file has unparseable lines:"
          : [printf "  line %d: %s" i e | (i, e) <- bad]
  when (null tasks) $ die "task file is empty"

  if opts.loChildren
    then do
      httpRuntime <- newHttpRuntime
      let work = [(p, probe, a) | p <- profiles, probe <- childProbes, a <- [1 .. opts.loRepeat]]
      printf "asking %d child request(s)\n\n" (length work)
      results <- withCompactLogger cfg.logColor Nothing $ \logger ->
        runEff . runLog "max-plan-live" logger LogAttention . runLLM httpRuntime (\_ _ _ -> pure ()) (\_ -> pure ()) cfg.llm $
          traverse (\(p, probe, a) -> askChild p probe a) work
      childReport profiles results
    else if opts.loDryRun
    then dryRun profiles tasks opts.loRepeat
    else do
      httpRuntime <- newHttpRuntime
      let plan =
            [ (profile, task, attempt)
              | profile <- profiles,
                task <- tasks,
                attempt <- [1 .. opts.loRepeat]
            ]
      printf
        "asking %d profile(s) × %d task(s) × %d attempt(s) = %d requests\n\n"
        (length profiles)
        (length tasks)
        opts.loRepeat
        (length plan)

      candidates <- withCompactLogger cfg.logColor Nothing $ \logger ->
        -- No database in this stack, so token usage is deliberately
        -- unaccounted, as in the other eval harnesses.
        runEff . runLog "max-plan-live" logger LogAttention . runLLM httpRuntime (\_ _ _ -> pure ()) (\_ -> pure ()) cfg.llm $
          traverse (\(p, t, a) -> ask p t a) plan

      report profiles candidates
      case opts.loOut of
        Nothing -> pure ()
        Just path -> do
          BL8.writeFile path (BL8.unlines (map (encode . candidateJson) candidates))
          printf "\nwrote %d candidates to %s\n" (length candidates) path

      let best =
            maximum
              (0 : [admitRate [c | c <- candidates, c.cdProfile == p] | p <- profiles])
      unless (best >= opts.loMinAdmit) $ do
        printf "\nFAIL: best admission rate %.3f below --min-admit %.3f\n" best opts.loMinAdmit
        exitFailure

dryRun :: [Text] -> [Task] -> Int -> IO ()
dryRun profiles tasks repeat' = do
  printf
    "would ask %d profile(s) × %d task(s) × %d attempt(s) = %d requests\n"
    (length profiles)
    (length tasks)
    repeat'
    (length profiles * length tasks * repeat')
  putStrLn "\nprofiles:"
  mapM_ (\p -> putStrLn ("  " <> T.unpack p)) profiles
  putStrLn "\ntasks:"
  mapM_ (\t -> putStrLn ("  " <> T.unpack t.tkName <> " — " <> T.unpack t.tkTask)) tasks
  case tasks of
    [] -> pure ()
    first' : _ -> do
      putStrLn "\n── the prompt, as the first task would receive it ────"
      putStrLn (T.unpack (frontPrompt (envFor first')))
      putStrLn ("\n[user] " <> T.unpack userTurn)

--------------------------------------------------------------------------------
-- The child half

-- | One subgoal, as a fork would hand it over.
--
-- Written here rather than in a fixture file because each one needs a
-- 'PlanSchema', and a text encoding of the type language would be a second
-- parser to keep in step with the first for no gain.
data ChildProbe = ChildProbe
  { cpName :: !Text,
    cpObjective :: !Text,
    -- | What the subgoal declared it would return, which is also — via
    -- 'jsonSchemaOf' — the argument schema of the tool it hands it back with.
    cpExpected :: !PlanSchema,
    -- | Values the subgoal named in its @inputs@ block. The projection ADR 007
    -- §12 added, exercised: a child that ignores what it was handed and
    -- answers about something else has failed in a way a schema check cannot
    -- see.
    cpInputs :: ![(Binder, Value)]
  }

-- | Three shapes, chosen for what each can fail at.
--
-- @text@ is the baseline: nothing to get wrong but the tool call itself.  The
-- object is the first shape where a model can return something plausible that
-- does not type.  The array-of-objects with an input is the real case — the
-- child must use what it was handed and produce a homogeneous list, which is
-- where a model that is narrating rather than answering shows up.
childProbes :: [ChildProbe]
childProbes =
  [ ChildProbe
      { cpName = "text",
        cpObjective = "用一句话说明 Haskell 里 newtype 和 data 的区别。",
        cpExpected = SchemaText,
        cpInputs = []
      },
    ChildProbe
      { cpName = "object",
        cpObjective = "介绍一下 PostgreSQL 这个数据库：名字和一段话的简介。",
        cpExpected =
          SchemaObject
            [ SchemaField {sfName = "name", sfSchema = SchemaText, sfRequired = True},
              SchemaField {sfName = "bio", sfSchema = SchemaText, sfRequired = True}
            ],
        cpInputs = []
      },
    ChildProbe
      { cpName = "array of objects, with an input",
        cpObjective = "按上面给的语言，列三个它最常用的 web 框架，每个给名字和一句话说明。",
        cpExpected =
          SchemaArray
            ( SchemaObject
                [ SchemaField {sfName = "framework", sfSchema = SchemaText, sfRequired = True},
                  SchemaField {sfName = "note", sfSchema = SchemaText, sfRequired = True}
                ]
            ),
        cpInputs = [(Binder "语言", String "Haskell")]
      }
  ]

-- | What one child attempt did.
data ChildOutcome
  = ChildFailed !Text
  | -- | Talked instead of returning.  The failure the brief exists to prevent:
    -- a child's prose goes nowhere, so this is an answer nobody will ever read.
    ChildTalked !Text
  | -- | Called the tool with something its own declared type does not describe.
    ChildOffSchema !Text !Value
  | ChildReturned !Value

data ChildCandidate = ChildCandidate
  { ccProfile :: !Text,
    ccProbe :: !Text,
    ccAttempt :: !Int,
    ccOutcome :: !ChildOutcome
  }

-- | The tool a fork child hands its answer back with, built exactly as
-- "Max.Tools.Subgoal" builds it: the argument schema /is/ the subgoal's
-- declared result type.
returnSpec :: ChildProbe -> ToolSpec
returnSpec probe =
  ToolSpec
    { specName = "subgoal_return",
      specDescription =
        "把这个子任务的结果交回去。你这一轮说的话没有人看得见，只有这里交的值会回到上层计划里。",
      specSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties" .= object ["result" .= jsonSchemaOf probe.cpExpected],
            "required" .= (["result"] :: [Text]),
            "additionalProperties" .= False
          ]
    }

askChild :: LLM :> es => Text -> ChildProbe -> Int -> Eff es ChildCandidate
askChild profile probe attempt = do
  result <-
    chat
      ctx
      profile
      [MsgSystem brief, MsgUser "开始吧。"]
      [returnSpec probe]
  pure
    ChildCandidate
      { ccProfile = profile,
        ccProbe = probe.cpName,
        ccAttempt = attempt,
        ccOutcome = case result of
          Left err -> ChildFailed err
          Right (ContentResp text) -> ChildTalked text
          Right (ToolCallsResp _ text calls) -> case [c | c <- calls, c.callName == "subgoal_return"] of
            [] -> ChildTalked text
            call : _ -> judgeReturn probe call.callArguments
      }
  where
    -- The production renderer, not a paraphrase of it: the words are the
    -- artifact under test.
    brief =
      subgoalBrief
        1
        Dispatchable
          { dpDesired =
              Desired
                { dsNode = NodeId "turn:0:0/k0",
                  dsBinder = Binder "child",
                  dsGoal = childGoal probe,
                  dsHash = ""
                },
            dpInputs = probe.cpInputs
          }
    ctx =
      ChatCtx
        { ccSource = "plan-live-child",
          ccGroup = Nothing,
          ccEffort = Nothing,
          ccTimeoutSeconds = Nothing,
          ccBufferedRetryDelaysSeconds = Nothing,
          ccAgentTurnId = Nothing,
          ccConfigGeneration = Nothing
        }

childGoal :: ChildProbe -> Goal
childGoal probe =
  planEnv.venGoal
    { goalObjective = probe.cpObjective,
      goalExpected = probe.cpExpected,
      goalInputs = map fst probe.cpInputs
    }

-- | The same check "Max.Tools.Subgoal" applies before writing anything down.
judgeReturn :: ChildProbe -> Value -> ChildOutcome
judgeReturn probe args = case args of
  Object o -> case KeyMap.lookup "result" o of
    Nothing -> ChildOffSchema "少了 result 这个参数" args
    Just returned -> case checkValue probe.cpExpected returned of
      Left mismatch -> ChildOffSchema (schemaErrorText mismatch) returned
      Right () -> ChildReturned returned
  _ -> ChildOffSchema "参数不是对象" args

childReport :: [Text] -> [ChildCandidate] -> IO ()
childReport profiles candidates = do
  putStrLn "── children ──────────────────────────────────────────"
  printf "  %-18s %8s %8s %10s %8s\n" ("profile" :: String) ("returned" :: String) ("talked" :: String) ("off-schema" :: String) ("failed" :: String)
  for_ profiles $ \profile -> do
    let mine = [c | c <- candidates, c.ccProfile == profile]
        count f = length [() | c <- mine, f c.ccOutcome]
    printf
      "  %-18s %8d %8d %10d %8d\n"
      (T.unpack profile)
      (count (\case ChildReturned {} -> True; _ -> False))
      (count (\case ChildTalked {} -> True; _ -> False))
      (count (\case ChildOffSchema {} -> True; _ -> False))
      (count (\case ChildFailed {} -> True; _ -> False))
  putStrLn ""
  for_ candidates $ \candidate -> do
    printf
      "  %-18s %-28s #%d  %s\n"
      (T.unpack candidate.ccProfile)
      (T.unpack candidate.ccProbe)
      candidate.ccAttempt
      ( case candidate.ccOutcome of
          ChildReturned returned -> "returned " <> clip 140 (shown returned)
          ChildOffSchema detail returned ->
            "OFF-SCHEMA " <> T.unpack detail <> " — " <> clip 100 (shown returned)
          ChildTalked text -> "TALKED " <> clip 100 (T.strip text)
          ChildFailed err -> "FAILED " <> clip 100 err
      )

-- | One request.  No tools are offered: a plan is written, not executed, and a
-- model that reaches for a tool anyway has told us something worth counting.
ask :: LLM :> es => Text -> Task -> Int -> Eff es Candidate
ask profile task attempt = do
  result <- chat ctx profile [MsgSystem (frontPrompt (envFor task)), MsgUser userTurn] []
  pure
    Candidate
      { cdProfile = profile,
        cdTask = task,
        cdAttempt = attempt,
        cdAttemptOutcome = case result of
          Left err -> Failed err
          Right (ContentResp text) -> readReply text False
          Right (ToolCallsResp _ text _) -> readReply text True
      }
  where
    ctx =
      ChatCtx
        { ccSource = "plan-live",
          ccGroup = Nothing,
          ccEffort = Nothing,
          ccTimeoutSeconds = Nothing,
          ccBufferedRetryDelaysSeconds = Nothing,
          ccAgentTurnId = Nothing,
          ccConfigGeneration = Nothing
        }

readReply :: Text -> Bool -> Attempt
readReply raw toolCalled
  | T.null (T.strip raw) = Silent
  | otherwise = Answered reply
  where
    source = unfence raw
    reply =
      Reply
        { rpRaw = raw,
          rpSource = source,
          rpFenced = isFenced raw,
          rpToolCalled = toolCalled,
          rpJudged = judge source
        }

candidateJson :: Candidate -> Value
candidateJson candidate =
  object $
    [ "profile" .= candidate.cdProfile,
      "task" .= candidate.cdTask.tkName,
      "attempt" .= candidate.cdAttempt
    ]
      <> case candidate.cdAttemptOutcome of
        Failed err -> ["error" .= err]
        Silent -> ["silent" .= True]
        Answered reply ->
          [ "raw" .= reply.rpRaw,
            "source" .= reply.rpSource,
            "fenced" .= reply.rpFenced,
            "tool_called" .= reply.rpToolCalled,
            "outcome" .= outcomeLabel reply.rpJudged.jOutcome,
            "class" .= outcomeClass reply.rpJudged.jOutcome,
            "detail" .= outcomeDetail reply.rpJudged.jOutcome,
            "holes" .= reply.rpJudged.jHoles,
            "tree_cost" .= reply.rpJudged.jTreeCost
          ]

-- | Only the attempts that produced something to judge.  Transport failures
-- and silences are not evidence about a model's grasp of the dialect, so they
-- are not in the denominator of any rate about it.
replies :: [Candidate] -> [Reply]
replies candidates = [reply | candidate <- candidates, Answered reply <- [candidate.cdAttemptOutcome]]

admitRate :: [Candidate] -> Double
admitRate candidates
  | null judged = 0
  | otherwise =
      fromIntegral (length [() | reply <- judged, Admitted {} <- [reply.rpJudged.jOutcome]])
        / fromIntegral (length judged)
  where
    judged = replies candidates

report :: [Text] -> [Candidate] -> IO ()
report profiles candidates = do
  putStrLn "── per profile ───────────────────────────────────────"
  printf
    "%-24s %5s %12s %12s %8s %8s %8s %8s\n"
    ("profile" :: String)
    ("judged" :: String)
    ("parsed" :: String)
    ("admitted" :: String)
    ("fenced" :: String)
    ("tools" :: String)
    ("silent" :: String)
    ("errors" :: String)
  mapM_ profileRow profiles
  putStrLn ""
  -- ADR 007 step 7.  Whether models decompose was never the open question;
  -- these are the parts a todo list does not contain.
  putStrLn "── decomposition, per task ───────────────────────────"
  printf
    "%-32s %6s %8s %8s %8s\n"
    ("task" :: String)
    ("forked" :: String)
    ("children" :: String)
    ("typed" :: String)
    ("punted" :: String)
  mapM_ taskRow (uniqueTasks candidates)
  putStrLn ""
  putStrLn "── rejection classes, all profiles ───────────────────"
  let classes =
        Map.toList $
          Map.fromListWith
            (+)
            [ (outcomeClass reply.rpJudged.jOutcome, 1 :: Int)
              | reply <- replies candidates,
                not (isAdmitted reply)
            ]
  if null classes
    then putStrLn "  (none)"
    else
      mapM_
        (\(cls, n) -> printf "  %-28s %d\n" (T.unpack cls) n)
        (sortOn (Down . snd) classes)
  where
    isAdmitted reply = case reply.rpJudged.jOutcome of
      Admitted {} -> True
      _ -> False

    uniqueTasks = foldr keepFirst [] . map (.cdTask.tkName)
      where
        keepFirst task seen = if task `elem` seen then seen else task : seen

    -- Counted over every reply that parsed, admitted or not: a plan that split
    -- the work correctly and then blew its budget still answers the question
    -- this table asks.
    taskRow task = do
      let shapes =
            [ shape
              | candidate <- candidates,
                candidate.cdTask.tkName == task,
                Answered reply <- [candidate.cdAttemptOutcome],
                Just shape <- [reply.rpJudged.jFork]
            ]
          forked = length [() | shape <- shapes, shape.fsForks > 0]
      printf
        "%-32s %6s %8d %8d %8d\n"
        (T.unpack task)
        (show forked <> "/" <> show (length shapes))
        (sum (map (.fsChildren) shapes))
        (sum (map (.fsTyped) shapes))
        (sum (map (.fsJoinPunted) shapes))

    profileRow profile = do
      let mine = [c | c <- candidates, c.cdProfile == profile]
          judged = replies mine
          errors = length [() | c <- mine, Failed _ <- [c.cdAttemptOutcome]]
          silent = length [() | c <- mine, Silent <- [c.cdAttemptOutcome]]
          parsed = length [() | reply <- judged, outcomeLabel reply.rpJudged.jOutcome /= "unparsed"]
          admitted = length [() | reply <- judged, isAdmitted reply]
          fenced = length [() | reply <- judged, reply.rpFenced]
          tools = length [() | reply <- judged, reply.rpToolCalled]
      printf
        "%-24s %5d %12s %12s %8d %8d %8d %8d\n"
        (T.unpack profile)
        (length judged)
        (rateOf parsed (length judged))
        (rateOf admitted (length judged))
        fenced
        tools
        silent
        errors

    rateOf :: Int -> Int -> String
    rateOf _ 0 = "n/a"
    rateOf n outOf = printf "%d (%d%%)" n ((n * 100) `div` outOf)

-- | JSON as characters rather than as bytes.  BL8.unpack would hand a terminal
-- one Latin-1 char per UTF-8 byte, which turns every Chinese answer in the
-- report into mojibake and makes a passing run look broken.
shown :: Value -> Text
shown = TE.decodeUtf8Lenient . BS8.toStrict . encode

clip :: Int -> Text -> String
clip n text
  | T.length text <= n = T.unpack text
  | otherwise = T.unpack (T.take n text) <> "…"
