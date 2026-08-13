-- | The plan tools against a fake plannable catalog.
--
-- The point of interest is the seam rather than the kernel, which its own specs
-- cover thoroughly: a plan submitted through @plan_run@ has to reach real tools,
-- through 'Max.Effects.Tools.runTools', at the effect row a tool actually runs
-- at — and reach *only* the plannable ones.  That is the claim this file exists
-- to hold down, because it is the one that would fail silently by degrading into
-- "no tool was ever called".
module Max.Tools.PlanSpec (spec) where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log (Log, LogLevel (LogAttention), runLog)
import Max.DB.Plan (PlanId (..), PlanOrdinal (..), PlanRef (..), PlanStatus (..), Revision (..), StoredPlan (..))
import Max.Plan.Execute (ExecState (..))
import Max.Effects.Tools
  ( SchemaVersion (..),
    Tool (..),
    ToolAuthority (..),
    ToolDefinition (..),
    ToolEffect (..),
    ToolParallelism (..),
    ToolRef (..),
    ToolRetryClass (..),
  )
import Max.Log (ColorMode (..), withCompactLogger)
import Max.Plan.Parse (parsePlan)
import Max.Plan.Types (Binder (..), PlanDocument (..), PlanPath (..), PlanStep (..), planHash)
import Max.Tools.Plan (PlanJournal (..), planToolsFor)
import Max.Tools.Schema (stringParam, toolObject)
import Max.Turn.Continuity (toolCatalogFingerprint)
import Max.Turn.Types (AgentTurnId (..))
import Test.Hspec

-- | Stand-ins for the two tools 'Max.Plan.Catalog' declares plannable, plus one
-- that is not, so "only plannable tools are reachable" has something to fail on.
fakeTools :: IORef [Text] -> [Tool '[Log, IOE]]
fakeTools calls =
  [ recorded
      "web_search"
      ( object
          [ "answer" .= Null,
            "results"
              .= [object ["title" .= ("燕大教务处" :: Text), "url" .= ("u" :: Text), "snippet" .= ("s" :: Text)]]
          ]
      ),
    recorded "memory_list" (toJSON ([] :: [Value])),
    recorded "poke" (object [])
  ]
  where
    recorded name result =
      Tool
        { toolName = name,
          toolDescription = name,
          toolSchema = toolObject [("query", stringParam "q"), ("scope", stringParam "s")] [],
          toolRun = \_ -> do
            liftIO (modifyIORef' calls (<> [name]))
            pure (Right result)
        }

definitions :: [ToolDefinition]
definitions =
  [ base "web_search" [EffectRead "network.search"],
    base "memory_list" [EffectRead "conversation.db"],
    base "poke" [EffectSend "chat.endpoint"],
    base "plan_guide" [EffectReflect],
    base "plan_run" [EffectRead "network.search", EffectRead "conversation.db"]
  ]
  where
    base name effects =
      ToolDefinition
        { tdRef = ToolRef name,
          tdSchemaVersion = SchemaVersion 1,
          tdEffects = Set.fromList effects,
          tdParallelism = SequentialOnly,
          tdRetryClass = RetrySafe,
          tdAuthorities = Set.singleton CurrentConversation,
          tdFailuresPrecedeEffects = False
        }

-- | Run one of the plan tools and hand back what it produced alongside the
-- tools the plan actually invoked.
invoke :: Text -> Value -> IO (Either Text Value, [Text])
invoke name args = do
  calls <- newIORef []
  out <- runToolWith nothingJournal calls name args
  (out,) <$> readIORef calls

-- | A journal that writes nothing, which is what a dispatch with no durable
-- turn gets.
nothingJournal :: PlanJournal '[Log, IOE]
nothingJournal =
  PlanJournal
    { pjRecord = \_ _ -> pure Nothing,
      pjSubgoal = Nothing,
      pjList = pure [],
      pjRevise = \_ _ _ -> pure (Left "not durable"),
      pjResolve = \_ -> pure Map.empty,
      pjSuspend = \_ _ _ _ -> pure False,
      pjSettle = \_ _ -> pure ()
    }

runToolWith :: PlanJournal '[Log, IOE] -> IORef [Text] -> Text -> Value -> IO (Either Text Value)
runToolWith journal calls name args = do
  let tools = planToolsFor journal definitions (fakeTools calls)
  case [t | t <- tools, t.toolName == name] of
    [] -> expectationFailure ("no such plan tool: " <> show name) >> error "unreachable"
    tool : _ ->
      withCompactLogger ColorNever Nothing $ \logger ->
        runEff . runLog "plan-test" logger LogAttention $ tool.toolRun args

field :: Text -> Value -> Maybe Value
field key (Object o) = KeyMap.lookup (Key.fromText key) o
field _ _ = Nothing

-- | Any plan identity; nothing under test reads it.
planRef :: PlanRef
planRef = PlanRef {prPlanId = PlanId 7, prOrdinal = PlanOrdinal 1}

-- | A call, then a fork of two subgoals, then a join that combines them.
-- Shaped after the guide's own fork example, so what is exercised here is what
-- a model is shown.
forkArgs :: Value
forkArgs =
  object
    [ "objective" .= ("查甲和乙" :: Text),
      "plan"
        .= T.unlines
          [ "let hits = web_search@1({ query: \"先看看\" })",
            "fork {",
            "  jia: hole \"查甲的资料\" : text",
            "    budget { calls: 1, sends: 0, fanout: 8, tokens: 4000, ms: 20000 }",
            "    effects { read(external \"web\") }",
            "  yi: hole \"查乙的资料\" : text",
            "    budget { calls: 1, sends: 0, fanout: 8, tokens: 4000, ms: 20000 }",
            "    effects { read(external \"web\") }",
            "}",
            "done concat(jia, \"｜\", yi)"
          ]
    ]

spec :: Spec
spec = do
  describe "plan_guide" $
    it "hands back the dialect with this turn's objective and catalog in it" $ do
      (out, calls) <- invoke "plan_guide" (object ["objective" .= ("查一下燕大教务处" :: Text)])
      calls `shouldBe` []
      case out of
        Left e -> expectationFailure (show e)
        Right value -> do
          let guide = case field "guide" value of
                Just (String t) -> t
                _ -> ""
          guide `shouldSatisfy` textContains "查一下燕大教务处"
          guide `shouldSatisfy` textContains "web_search@1"
          -- The whole reason the sub-catalog exists: a tool max has and a plan
          -- may not call is absent from what the model is shown, so it is not
          -- offered a guaranteed rejection.
          guide `shouldSatisfy` (not . textContains "poke@")
          guide `shouldSatisfy` (not . textContains "plan_run@")

  describe "plan_run" $ do
    it "resolves an explicitly authored result handle through the journal" $ do
      requested <- newIORef ([] :: [Text])
      calls <- newIORef []
      let journal =
            nothingJournal
              { pjResolve = \handles -> do
                  liftIO (writeIORef requested handles)
                  pure (Map.fromList [("t#1:r1", object ["answer" .= ("甲" :: Text)])])
              }
      out <-
        runToolWith
          journal
          calls
          "plan_run"
          (object ["objective" .= ("复用结果" :: Text), "plan" .= ("done t#1:r1.answer" :: Text)])
      readIORef requested `shouldReturn` ["t#1:r1"]
      fmap (field "done") out `shouldBe` Right (Just (String "甲"))

    it "runs a plan end to end and returns only its done value" $ do
      (out, calls) <-
        invoke
          "plan_run"
          ( object
              [ "objective" .= ("查一下燕大教务处" :: Text),
                "plan"
                  .= ( "let hits = web_search@1({ query: \"燕山大学 教务处\" })\n\
                       \done hits.results[0].title ?? \"没搜到\""
                       :: Text
                     )
              ]
          )
      calls `shouldBe` ["web_search"]
      case out of
        Left e -> expectationFailure (show e)
        Right value -> do
          -- The search hit itself never appears; one projected field does.
          field "done" value `shouldBe` Just (String "燕大教务处")
          field "calls_used" value `shouldBe` Just (Number 1)

    it "accepts a string literal where the catalog declares an enum" $ do
      -- Found by asking a real model to plan against the real catalog: it wrote
      -- memory_list@1({ scope: "group" }) and the kernel refused it, because
      -- synthesis gives a literal the type text and text does not satisfy an
      -- enum.  There is no other spelling — the grammar has enum as a type and
      -- no literal form for one — so every enum-typed parameter max has was
      -- uncallable from a plan, and the model was being told its only option
      -- was wrong.
      (out, calls) <-
        invoke
          "plan_run"
          ( object
              [ "objective" .= ("看看群记忆" :: Text),
                "plan"
                  .= ( "let mems = memory_list@1({ scope: \"group\" })\n\
                       \done concat(\"记了 \", \"若干\", \" 条\")"
                       :: Text
                     )
              ]
          )
      calls `shouldBe` ["memory_list"]
      fmap (field "done") out `shouldBe` Right (Just (String "记了 若干 条"))

    it "still refuses a string that is not one of the enum's members" $ do
      (out, calls) <-
        invoke
          "plan_run"
          ( object
              [ "objective" .= ("看看群记忆" :: Text),
                "plan" .= ("let mems = memory_list@1({ scope: \"everyone\" })\ndone \"x\"" :: Text)
              ]
          )
      calls `shouldBe` []
      out `shouldSatisfy` isLeftContaining "everyone"

    it "records the admitted plan before running it, and only when admitted" $ do
      -- The recorder is the seam the durable half hangs off, and the ordering
      -- is the claim: a plan that was admitted and then died mid-execution is
      -- exactly the one worth having on disk, so the write cannot wait for a
      -- result.  A rejected plan is not a plan and leaves no row.
      recorded <- newIORef ([] :: [PlanDocument])
      calls <- newIORef []
      let journal =
            nothingJournal
              {pjRecord = \_ document -> liftIO (modifyIORef' recorded (<> [document])) >> pure Nothing}
          run = runToolWith journal calls "plan_run"
      _ <-
        run
          ( object
              [ "objective" .= ("查一下" :: Text),
                "plan" .= ("let hits = web_search@1({ query: \"q\" })\ndone \"ok\"" :: Text)
              ]
          )
      _ <- run (object ["objective" .= ("坏的" :: Text), "plan" .= ("这不是计划" :: Text)])
      documents <- readIORef recorded
      map (.pdRoot) documents `shouldBe` ["plan:查一下"]
      map (planHash . (.pdPlan)) documents
        `shouldBe` [planHash plan | Right plan <- [parsePlan "let hits = web_search@1({ query: \"q\" })\ndone \"ok\""]]

    it "refuses a plan naming a tool that exists but is not plannable" $ do
      (out, calls) <-
        invoke
          "plan_run"
          ( object
              [ "objective" .= ("戳一下" :: Text),
                "plan" .= ("let sent = poke@1({ query: \"x\" })\ndone \"ok\"" :: Text)
              ]
          )
      -- Refused by the kernel, so nothing ran at all — not refused at
      -- invocation time after the plan had already done other work.
      calls `shouldBe` []
      out `shouldSatisfy` isLeftContaining "poke"

    it "reports a parse failure as something to fix rather than as a crash" $ do
      (out, calls) <-
        invoke "plan_run" (object ["objective" .= ("x" :: Text), "plan" .= ("这不是计划" :: Text)])
      calls `shouldBe` []
      out `shouldSatisfy` isLeftContaining "没解析通过"

    it "reports a hole as a stop, keeping the work already done" $ do
      -- Holes are not elaborated in this slice.  The model has to be told that
      -- clearly and told what did run, or it repeats the search by hand.
      (out, calls) <-
        invoke
          "plan_run"
          ( object
              [ "objective" .= ("查然后总结" :: Text),
                "plan"
                  .= ( "let hits = web_search@1({ query: \"q\" })\n\
                       \hole \"怎么总结\" : text budget { calls: 0, sends: 0, fanout: 1, tokens: 100, ms: 100 }"
                       :: Text
                     )
              ]
          )
      calls `shouldBe` ["web_search"]
      case out of
        Left e -> expectationFailure (show e)
        Right value -> do
          field "done" value `shouldBe` Nothing
          field "tools_run" value `shouldBe` Just (toJSON ["web_search" :: Text])
          case field "stopped" value of
            Just (String t) -> t `shouldSatisfy` textContains "怎么总结"
            other -> expectationFailure ("expected a stop reason, got " <> show other)

    describe "a fork" $ do
      it "parks the walk and tells the model not to do the work itself" $ do
        parked <- newIORef ([] :: [(Revision, Text, Value)])
        calls <- newIORef []
        let journal =
              nothingJournal
                { pjRecord = \_ _ -> pure (Just planRef),
                  pjSuspend = \_ based node state ->
                    liftIO (modifyIORef' parked (<> [(based, node, state)])) >> pure True
                }
        out <- runToolWith journal calls "plan_run" forkArgs
        readIORef calls `shouldReturn` ["web_search"]
        case out of
          Left e -> expectationFailure (show e)
          Right value -> do
            -- Not a stop.  Nothing went wrong, nothing is waiting on this
            -- turn, and picking the work up by hand here would race the
            -- children about to do it.
            field "stopped" value `shouldBe` Nothing
            field "suspended" value
              `shouldBe` Just
                ( toJSON
                    [ object ["binder" .= ("jia" :: Text), "objective" .= ("查甲的资料" :: Text)],
                      object ["binder" .= ("yi" :: Text), "objective" .= ("查乙的资料" :: Text)]
                    ]
                )
            field "tools_run" value `shouldBe` Just (toJSON ["web_search" :: Text])

      it "checkpoints where the walk actually stood, not where it started" $ do
        -- The reason Step carries the state at all: walk descends through let
        -- and if without returning, so the state the driver handed in names a
        -- node several steps back, and resuming from it would redo the search.
        parked <- newIORef ([] :: [(Revision, Text, Value)])
        calls <- newIORef []
        let journal =
              nothingJournal
                { pjRecord = \_ _ -> pure (Just planRef),
                  pjSuspend = \_ based node state ->
                    liftIO (modifyIORef' parked (<> [(based, node, state)])) >> pure True
                }
        _ <- runToolWith journal calls "plan_run" forkArgs
        readIORef parked >>= \case
          [(based, node, state)] -> do
            based `shouldBe` Revision 1
            node `shouldSatisfy` textContains "/c"
            case fromJSON state of
              Error e -> expectationFailure ("checkpoint did not decode: " <> e)
              Success (decoded :: ExecState) -> do
                decoded.esPath `shouldBe` PlanPath [StepContinue]
                Map.keys decoded.esBindings `shouldBe` [Binder "hits"]
                decoded.esCalls `shouldBe` 1
          other -> expectationFailure ("expected exactly one suspension, got " <> show (length other))

      it "closes a plan that ended inside the call, and only that one" $ do
        -- A plan left open sits in the steerable set forever, so a later steer
        -- would land on work nobody is doing.  A parked fork is the one ending
        -- that outlives the call and must stay open.
        settled <- newIORef ([] :: [PlanStatus])
        calls <- newIORef []
        let journal =
              nothingJournal
                { pjRecord = \_ _ -> pure (Just planRef),
                  pjSuspend = \_ _ _ _ -> pure True,
                  pjSettle = \_ status -> liftIO (modifyIORef' settled (<> [status]))
                }
        _ <- runToolWith journal calls "plan_run" forkArgs
        readIORef settled `shouldReturn` []
        _ <-
          runToolWith
            journal
            calls
            "plan_run"
            ( object
                [ "objective" .= ("查一下" :: Text),
                  "plan" .= ("let hits = web_search@1({ query: \"q\" })\ndone \"ok\"" :: Text)
                ]
            )
        readIORef settled `shouldReturn` [PlanDone]

      it "falls back to reporting a stop when the plan moved underneath it" $ do
        -- A steer landed between admitting this plan and reaching its fork.
        -- The work already done still counts, and the model is the one who can
        -- say what the change meant.
        calls <- newIORef []
        let journal = nothingJournal {pjRecord = \_ _ -> pure (Just planRef)}
        out <- runToolWith journal calls "plan_run" forkArgs
        case out of
          Left e -> expectationFailure (show e)
          Right value -> do
            field "suspended" value `shouldBe` Nothing
            case field "stopped" value of
              Just (String t) -> t `shouldSatisfy` textContains "fork"
              other -> expectationFailure ("expected a stop reason, got " <> show other)

      it "reports a stop when there is no durable plan to park against" $ do
        -- A dispatch with no turn has nothing to hang a suspension off.  The
        -- honest answer is the old one, not a promise nobody will keep.
        (out, _) <- invoke "plan_run" forkArgs
        case out of
          Left e -> expectationFailure (show e)
          Right value -> do
            field "suspended" value `shouldBe` Nothing
            field "stopped" value `shouldSatisfy` (/= Nothing)

    it "refuses a plan over its call budget before running any of it" $ do
      (out, calls) <-
        invoke
          "plan_run"
          ( object
              [ "objective" .= ("查五次" :: Text),
                "plan"
                  .= ( "let a = web_search@1({ query: \"1\" })\n\
                       \let b = web_search@1({ query: \"2\" })\n\
                       \let c = web_search@1({ query: \"3\" })\n\
                       \let d = web_search@1({ query: \"4\" })\n\
                       \let e = web_search@1({ query: \"5\" })\n\
                       \done \"ok\""
                       :: Text
                     )
              ]
          )
      calls `shouldBe` []
      out `shouldSatisfy` isLeftContaining "没通过校验"

  describe "plan_revise" $
    it "rejects a tool whose current definition no longer matches the plan's frozen grant" $ do
      calls <- newIORef []
      revisions <- newIORef ([] :: [PlanDocument])
      original <- case parsePlan "done \"old\"" of
        Left failure -> expectationFailure (show failure) >> error "unreachable"
        Right plan -> pure plan
      webDefinition <- case [definition | definition <- definitions, definition.tdRef == ToolRef "web_search"] of
        [definition] -> pure definition
        found -> expectationFailure ("expected one web_search definition, got " <> show (length found)) >> error "unreachable"
      let stored =
            StoredPlan
              { stRef = planRef,
                stRevision = Revision 1,
                stStatus = PlanOpen,
                stRootTurn = AgentTurnId 1,
                stDocument = PlanDocument "plan:old" original,
                stRootGoal = Nothing,
                stServesSubgoal = False,
                -- Same name, different definition. Name-only validation would
                -- silently widen the old plan at this steering boundary.
                stToolGrants = Map.singleton "web_search" (toolCatalogFingerprint [webDefinition] <> "-drifted"),
                stUpdatedAt = read "2026-08-11 00:00:00 UTC"
              }
          journal =
            nothingJournal
              { pjList = pure [Right stored],
                pjRevise = \_ _ document -> do
                  liftIO (modifyIORef' revisions (<> [document]))
                  pure (Right (Revision 2))
              }
      out <-
        runToolWith
          journal
          calls
          "plan_revise"
          ( object
              [ "plan" .= (1 :: Int),
                "revision" .= (1 :: Int),
                "objective" .= ("查一下" :: Text),
                "source" .= ("let hits = web_search@1({ query: \"q\" })\ndone \"ok\"" :: Text)
              ]
          )
      out `shouldSatisfy` isLeftContaining "web_search"
      readIORef revisions `shouldReturn` []

textContains :: Text -> Text -> Bool
textContains = T.isInfixOf

isLeftContaining :: Text -> Either Text Value -> Bool
isLeftContaining needle = \case
  Left message -> textContains needle message
  Right _ -> False
