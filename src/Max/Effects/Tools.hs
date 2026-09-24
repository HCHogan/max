{-# LANGUAGE TypeFamilies #-}

-- | Tool execution boundary: validate inputs, enforce deadlines and classify
-- results. Read-only consumers use ToolDirectory and never acquire closures.
module Max.Effects.Tools
  ( Tools,
    Tool (..),
    ToolRunner (..),
    legacyTool,
    toolRun,
    hoistTool,
    ToolRegistry,
    buildToolRegistry,
    registryCatalog,
    runTools,
    runToolsWith,
    invokeTool,
    invokeToolWithControl,
    outcomeResult,
    module Max.Tool.Types,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (race)
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Tool.Bundles (SkillLoad (..), skillReceiptVersion)
import Max.Tool.Catalog
  ( ToolCatalog,
    buildToolCatalog,
    lookupCatalogTool,
    validateArguments,
  )
import Max.Tool.Control (LoopControl (..))
import Max.Tool.Returns (withReturnType)
import Max.Tool.Types
import Max.Util (trySync)

data Tool es = Tool
  { toolName :: !Text,
    toolDescription :: !Text,
    toolSchema :: !Value,
    toolRunner :: !(ToolRunner es)
  }

-- | Unclassified adapters cannot claim a failure preceded effects. Typed
-- domain runners report the stage at the point where the result is known.
data ToolRunner es
  = LegacyRunner (Value -> Eff es (Either Text Value))
  | OutcomeRunner (Value -> Eff es ToolOutcome)

legacyTool :: Text -> Text -> Value -> (Value -> Eff es (Either Text Value)) -> Tool es
legacyTool name description schema run = Tool name description schema (LegacyRunner run)

-- | Compatibility projection for direct callers. The execution kernel retains
-- the richer result and never uses this lossy view to make recovery decisions.
toolRun :: Tool es -> Value -> Eff es (Either Text Value)
toolRun tool args = case tool.toolRunner of
  LegacyRunner run -> run args
  OutcomeRunner run -> outcomeResult <$> run args

hoistTool :: (forall x. Eff source x -> Eff target x) -> Tool source -> Tool target
hoistTool lower tool = Tool tool.toolName tool.toolDescription tool.toolSchema $ case tool.toolRunner of
  LegacyRunner run -> LegacyRunner (lower . run)
  OutcomeRunner run -> OutcomeRunner (lower . run)

data RegisteredTool es = RegisteredTool
  { rtView :: !CatalogTool,
    rtRun :: Value -> Eff es ToolOutcome
  }

data ToolRegistry es = ToolRegistry
  { registryCatalog :: !ToolCatalog,
    registryRunners :: !(Map ToolRef (RegisteredTool es))
  }

instance Show (ToolRegistry es) where
  show = show . registryCatalog

buildToolRegistry :: [ToolDefinition] -> [Tool es] -> Either ToolCatalogError (ToolRegistry es)
buildToolRegistry definitions runners = do
  catalog <- buildToolCatalog definitions [ToolSpec t.toolName (withReturnType t.toolName t.toolDescription) t.toolSchema | t <- runners]
  registered <- traverse (register catalog) runners
  pure (ToolRegistry catalog (Map.fromList registered))
  where
    register catalog runner = do
      let ref = ToolRef runner.toolName
      view <- maybe (Left (MissingToolDefinition ref)) Right (lookupCatalogTool ref catalog)
      let run args = case runner.toolRunner of
            OutcomeRunner action -> action args
            LegacyRunner action -> either (legacyFailure view.ctDefinition) (success view.ctDefinition) <$> action args
      pure (ref, RegisteredTool view run)

data Tools :: Effect where
  InvokeTool :: Text -> Value -> Tools m ToolInvocation

type instance DispatchOf Tools = Dynamic

runTools :: (Concurrent :> es) => ToolRegistry es -> Eff (Tools : es) a -> Eff es a
runTools registry = runToolsWith (fmap (,ContinueLoop)) (pure registry)

-- | Install runner capabilities at assembly; business tools keep their narrow
-- effects. The registry is refreshed only between model rounds.
runToolsWith ::
  forall es toolEs a.
  (Concurrent :> es) =>
  (forall x. Eff toolEs x -> Eff es (x, LoopControl)) ->
  Eff es (ToolRegistry toolEs) ->
  Eff (Tools : es) a ->
  Eff es a
runToolsWith lower currentRegistry = interpret $ \_ -> \case
  InvokeTool name args -> do
    registry <- currentRegistry
    sanitizeInvocation <$> case Map.lookup (ToolRef name) registry.registryRunners of
      Nothing -> pure . ordinary . ToolRejected $ ToolFault "unknown_tool" ("unknown tool: " <> name) RetrySafe
      Just registered -> case validateArguments registered.rtView args of
        Left fault -> pure (ordinary (ToolRejected fault))
        Right () -> execute args registered
  where
    execute :: Value -> RegisteredTool toolEs -> Eff es ToolInvocation
    execute args registered = do
      attempted <- trySync (race (threadDelay deadlineMicros) (lower (registered.rtRun args)))
      pure $ case attempted of
        -- An exception or timeout cannot carry a runner's explicit outcome:
        -- it may have interrupted a write before acknowledgement arrived.
        Left exception -> failure "exception" (T.pack (show exception))
        Right (Left ()) ->
          failure "timeout" ("工具执行超时（" <> T.pack (show seconds) <> " 秒）")
        Right (Right (outcome, control)) -> case outcome of
          ToolSucceeded _ -> completed outcome control
          ToolCommitted _ -> completed outcome control
          _ -> ordinary outcome
      where
        completed outcome control
          | permitsControl definition control = ToolInvocation outcome control
          | otherwise = ordinary (ToolOutcomeUnknown (ToolFault "invalid_host_control" "runner control conflicts with its declared execution mode" RetryUnsafe))
        definition = registered.rtView.ctDefinition
        seconds = definition.tdDeadline.toolDeadlineSeconds
        deadlineMicros = seconds * 1_000_000
        failure code message =
          let fault = ToolFault code message definition.tdRetryClass
           in if hasCommitEffects definition
                then ordinary (ToolOutcomeUnknown fault)
                else ordinary (ToolFailedBeforeEffect fault)

legacyFailure :: ToolDefinition -> Text -> ToolOutcome
legacyFailure definition message =
  (if hasCommitEffects definition then ToolOutcomeUnknown else ToolFailedBeforeEffect)
    (ToolFault "tool_error" message definition.tdRetryClass)

success :: ToolDefinition -> Value -> ToolOutcome
success definition = if hasCommitEffects definition then ToolCommitted else ToolSucceeded

-- Skill activation requires a sequential reflection tool.
permitsControl :: ToolDefinition -> LoopControl -> Bool
permitsControl _ ContinueLoop = True
permitsControl definition (LoadSkills _) = definition.tdParallelism == SequentialOnly && EffectReflect `elem` definition.tdEffects

ordinary :: ToolOutcome -> ToolInvocation
ordinary outcome = ToolInvocation outcome ContinueLoop

sanitizeInvocation :: ToolInvocation -> ToolInvocation
sanitizeInvocation invocation = ToolInvocation (sanitizeToolOutcome invocation.tiOutcome) (sanitizeControl invocation.tiControl)
  where
    sanitizeControl (LoadSkills loads) =
      LoadSkills
        [ updated {slVersion = skillReceiptVersion updated}
        | load <- loads,
          let updated = load {slInstructions = sanitizeToolText load.slInstructions, slMetadata = sanitizeToolValue <$> load.slMetadata}
        ]
    sanitizeControl ContinueLoop = ContinueLoop

-- PostgreSQL JSONB cannot represent U+0000, while external tools and scraped
-- web snippets can.  Normalise once at the tool kernel boundary so the durable
-- execution journal and the exact result returned to the model never diverge:
-- both observe U+FFFD at the same position.  Object keys need the same walk as
-- string values; faults are persisted as text and therefore need it too.
sanitizeToolOutcome :: ToolOutcome -> ToolOutcome
sanitizeToolOutcome = \case
  ToolRejected fault -> ToolRejected (sanitizeToolFault fault)
  ToolFailedBeforeEffect fault -> ToolFailedBeforeEffect (sanitizeToolFault fault)
  ToolSucceeded value -> ToolSucceeded (sanitizeToolValue value)
  ToolCommitted value -> ToolCommitted (sanitizeToolValue value)
  ToolOutcomeUnknown fault -> ToolOutcomeUnknown (sanitizeToolFault fault)

sanitizeToolFault :: ToolFault -> ToolFault
sanitizeToolFault fault =
  fault
    { tfCode = sanitizeToolText fault.tfCode,
      tfMessage = sanitizeToolText fault.tfMessage
    }

sanitizeToolValue :: Value -> Value
sanitizeToolValue = \case
  Object fields ->
    Object . KeyMap.fromList $
      [ (Key.fromText (sanitizeToolText (Key.toText key)), sanitizeToolValue value)
      | (key, value) <- KeyMap.toList fields
      ]
  Array values -> Array (sanitizeToolValue <$> values)
  String value -> String (sanitizeToolText value)
  other -> other

sanitizeToolText :: Text -> Text
sanitizeToolText = T.map (\char -> if char == '\0' then '\xfffd' else char)

hasCommitEffects :: ToolDefinition -> Bool
hasCommitEffects = any isCommitEffect . (.tdEffects)
  where
    isCommitEffect EffectWrite {} = True
    isCommitEffect EffectSend {} = True
    isCommitEffect _ = False

invokeTool :: (Tools :> es) => Text -> Value -> Eff es ToolOutcome
invokeTool name args = (.tiOutcome) <$> invokeToolWithControl name args

invokeToolWithControl :: (Tools :> es) => Text -> Value -> Eff es ToolInvocation
invokeToolWithControl name args = send (InvokeTool name args)

outcomeResult :: ToolOutcome -> Either Text Value
outcomeResult = \case
  ToolRejected fault -> Left fault.tfMessage
  ToolFailedBeforeEffect fault -> Left fault.tfMessage
  ToolSucceeded value -> Right value
  ToolCommitted value -> Right value
  ToolOutcomeUnknown fault -> Left (fault.tfMessage <> " (outcome unknown; not retried)")
