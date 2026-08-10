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
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log (Log, LogLevel (LogAttention), runLog)
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
import Max.Plan.Types (PlanDocument (..), planHash)
import Max.Tools.Plan (planToolsFor)
import Max.Tools.Schema (stringParam, toolObject)
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
  let tools = planToolsFor (const (pure Nothing)) definitions (fakeTools calls)
  case [t | t <- tools, t.toolName == name] of
    [] -> expectationFailure ("no such plan tool: " <> show name) >> error "unreachable"
    tool : _ -> do
      out <-
        withCompactLogger ColorNever Nothing $ \logger ->
          runEff . runLog "plan-test" logger LogAttention $ tool.toolRun args
      (out,) <$> readIORef calls

field :: Text -> Value -> Maybe Value
field key (Object o) = KeyMap.lookup (Key.fromText key) o
field _ _ = Nothing

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
      let tools =
            planToolsFor
              (\document -> liftIO (modifyIORef' recorded (<> [document])) >> pure Nothing)
              definitions
              (fakeTools calls)
          run args = case [t | t <- tools, t.toolName == "plan_run"] of
            tool : _ ->
              withCompactLogger ColorNever Nothing $ \logger ->
                runEff . runLog "plan-test" logger LogAttention $ tool.toolRun args
            [] -> error "no plan_run"
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

textContains :: Text -> Text -> Bool
textContains = T.isInfixOf

isLeftContaining :: Text -> Either Text Value -> Bool
isLeftContaining needle = \case
  Left message -> textContains needle message
  Right _ -> False
