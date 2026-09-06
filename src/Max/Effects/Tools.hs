{-# LANGUAGE TypeFamilies #-}

-- | Tool execution boundary: validate inputs, enforce deadlines and classify
-- results. Read-only consumers use ToolDirectory and never acquire closures.
module Max.Effects.Tools
  ( Tools,
    Tool (..),
    hoistTool,
    ToolRegistry,
    buildToolRegistry,
    registryCatalog,
    runTools,
    runToolsWith,
    runToolsWithControl,
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
import Max.Tool.Catalog (ToolCatalog, buildToolCatalog, lookupCatalogTool, validateArguments)
import Max.Tool.Control (LoopControl (..), mapControlText)
import Max.Tool.Types
import Max.Util (trySync)

data Tool es = Tool
  { toolName :: !Text,
    toolDescription :: !Text,
    toolSchema :: !Value,
    toolRun :: Value -> Eff es (Either Text Value)
  }

hoistTool :: (forall x. Eff source x -> Eff target x) -> Tool source -> Tool target
hoistTool lower tool = Tool tool.toolName tool.toolDescription tool.toolSchema (lower . tool.toolRun)

data RegisteredTool es = RegisteredTool
  { rtView :: !CatalogTool,
    rtRun :: Value -> Eff es (Either Text Value)
  }

data ToolRegistry es = ToolRegistry
  { registryCatalog :: !ToolCatalog,
    registryRunners :: !(Map ToolRef (RegisteredTool es))
  }

instance Show (ToolRegistry es) where
  show = show . registryCatalog

buildToolRegistry :: [ToolDefinition] -> [Tool es] -> Either ToolCatalogError (ToolRegistry es)
buildToolRegistry definitions runners = do
  catalog <- buildToolCatalog definitions [ToolSpec t.toolName t.toolDescription t.toolSchema | t <- runners]
  registered <- traverse (register catalog) runners
  pure (ToolRegistry catalog (Map.fromList registered))
  where
    register catalog runner = do
      let ref = ToolRef runner.toolName
      view <- maybe (Left (MissingToolDefinition ref)) Right (lookupCatalogTool ref catalog)
      pure (ref, RegisteredTool view runner.toolRun)

data Tools :: Effect where
  InvokeTool :: Text -> Value -> Tools m ToolInvocation

type instance DispatchOf Tools = Dynamic

runTools :: (Concurrent :> es) => ToolRegistry es -> Eff (Tools : es) a -> Eff es a
runTools = runToolsWith id

-- | Install runner capabilities in the assembly layer. The agent does not
-- inherit the effects used by a runner (in particular, media production).
runToolsWith ::
  forall es toolEs a.
  (Concurrent :> es) =>
  (forall x. Eff toolEs x -> Eff es x) ->
  ToolRegistry toolEs ->
  Eff (Tools : es) a ->
  Eff es a
runToolsWith lower = runToolsWithControl (fmap (,ContinueLoop) . lower)

runToolsWithControl ::
  forall es toolEs a.
  (Concurrent :> es) =>
  (forall x. Eff toolEs x -> Eff es (x, LoopControl)) ->
  ToolRegistry toolEs ->
  Eff (Tools : es) a ->
  Eff es a
runToolsWithControl lower registry = interpret $ \_ -> \case
  InvokeTool name args ->
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
        -- A thrown exception is never covered by the pre-effect promise: the
        -- tool did not choose to stop, so it may have died between issuing a
        -- write and hearing back about it.
        Left exception -> failure False "exception" (T.pack (show exception))
        -- Neither is running out of time, and for the same reason twice over:
        -- the tool did not choose to stop, and it was cut off at a moment
        -- nobody picked.  Even a tool that has been audited as failing before
        -- its effects gets no credit here, because this is not one of its
        -- failure paths.
        Right (Left ()) ->
          failure False "timeout" ("工具执行超时（" <> T.pack (show seconds) <> " 秒）")
        Right (Right (Left message, _)) ->
          failure definition.tdFailuresPrecedeEffects "tool_error" message
        Right (Right (Right value, control))
          | permitsControl definition control ->
              ToolInvocation (if hasCommitEffects definition then ToolCommitted value else ToolSucceeded value) control
          | otherwise ->
              ordinary (ToolOutcomeUnknown (ToolFault "invalid_host_control" "runner control conflicts with its declared execution mode" RetryUnsafe))
      where
        definition = registered.rtView.ctDefinition
        seconds = definition.tdDeadline.toolDeadlineSeconds
        deadlineMicros = seconds * 1_000_000
        failure precedesEffects code message =
          let fault = ToolFault code message definition.tdRetryClass
           in if hasCommitEffects definition && not precedesEffects
                then ordinary (ToolOutcomeUnknown fault)
                else ordinary (ToolFailedBeforeEffect fault)

-- A runner can stop the loop only within its host-declared execution mode.
permitsControl :: ToolDefinition -> LoopControl -> Bool
permitsControl _ ContinueLoop = True
permitsControl definition (YieldLoop _) = definition.tdCallMode == WorkCall && definition.tdParallelism == SequentialOnly
permitsControl definition (FinishLoop _) = definition.tdCallMode == FinishCall

ordinary :: ToolOutcome -> ToolInvocation
ordinary outcome = ToolInvocation outcome ContinueLoop

sanitizeInvocation :: ToolInvocation -> ToolInvocation
sanitizeInvocation invocation = ToolInvocation (sanitizeToolOutcome invocation.tiOutcome) (mapControlText sanitizeToolText invocation.tiControl)

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
