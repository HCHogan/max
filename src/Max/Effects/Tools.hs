{-# LANGUAGE TypeFamilies #-}

-- |
-- Validated tool catalog and execution boundary.
--
-- A tool runner is still an in-process closure, but it can only be reached
-- through a 'ToolCatalog'.  Catalog construction binds the closure to stable
-- metadata, validates its JSON schema, rejects duplicate or drifting names,
-- and computes the schema hash used by plans and diagnostics.
--
-- The interpreter also normalises execution into 'ToolOutcome'.  This keeps
-- model-facing error text compatible with the old @Either Text Value@ runners
-- while making retry/deoptimisation safety explicit to orchestration code.
module Max.Effects.Tools
  ( Tools,
    Tool (..),
    ToolRef (..),
    SchemaVersion (..),
    SchemaHash (..),
    ToolEffect (..),
    ToolParallelism (..),
    ToolRetryClass (..),
    ToolAuthority (..),
    ToolDeadline (..),
    ToolDefinition (..),
    CatalogTool (..),
    ToolCatalog,
    ToolCatalogError (..),
    ToolFault (..),
    ToolOutcome (..),
    buildToolCatalog,
    catalogTools,
    runTools,
    listToolSpecs,
    listCatalogTools,
    invokeTool,
    outcomeResult,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Control.Exception (Exception)
import Data.Aeson (Object, Value (..), encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (foldlM, toList, traverse_)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (floatingOrInteger)
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (race)
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Effects.LLM (ToolSpec (..))
import Max.Util (trySync)

-- | Existing tool implementation surface.  Runners retain their historical
-- result type so individual tools can be migrated without changing the wire
-- errors the model has learned to recover from.  They are never registered
-- directly: 'buildToolCatalog' first binds them to a 'ToolDefinition'.
data Tool es = Tool
  { toolName :: !Text,
    toolDescription :: !Text,
    toolSchema :: !Value,
    toolRun :: Value -> Eff es (Either Text Value)
  }

newtype ToolRef = ToolRef {unToolRef :: Text}
  deriving stock (Show, Eq, Ord)

newtype SchemaVersion = SchemaVersion {unSchemaVersion :: Int}
  deriving stock (Show, Eq, Ord)

newtype SchemaHash = SchemaHash {unSchemaHash :: Text}
  deriving stock (Show, Eq, Ord)

-- | Effects relevant to scheduling, approvals and recovery.  Domains are
-- stable machine-readable identifiers such as @conversation.db@ or
-- @sandbox.fs@; they are deliberately not user-facing prose.
data ToolEffect
  = EffectRead !Text
  | EffectWrite !Text
  | EffectSend !Text
  | EffectLLM
  | EffectReflect
  deriving stock (Show, Eq, Ord)

data ToolParallelism
  = ParallelSafe
  | SequentialOnly
  deriving stock (Show, Eq, Ord)

data ToolRetryClass
  = RetrySafe
  | RetryIdempotent
  | RetryUnsafe
  deriving stock (Show, Eq, Ord)

-- | Start-to-close: how long one call of this tool may run before the kernel
-- stops waiting for it.
--
-- Declared per tool because there is no one number.  Production spans four
-- orders of magnitude in the same catalog — @set_reminder@ finishes in
-- milliseconds, @sandbox_exec@ is allowed to ask for ten minutes — so a single
-- global bound would either be under the legitimate maximum or so far above it
-- that it bounds nothing.
--
-- Temporal's word for this is start-to-close, and its reasoning applies
-- unchanged: the layer above cannot detect a silently wedged worker, so it
-- depends on this to force the call to end.  The turn's silence watchdog is
-- the layer above here, and it can only kill the whole turn; this ends one
-- call and hands the model something it can act on.
newtype ToolDeadline = ToolDeadline {toolDeadlineSeconds :: Int}
  deriving stock (Show, Eq, Ord)

-- | Authority the tool runner may consume.  Conversation authority is minted
-- from the current turn; it is never reconstructed from model arguments.
data ToolAuthority
  = CurrentConversation
  | CurrentEndpoint
  | ProcessResource !Text
  deriving stock (Show, Eq, Ord)

-- | Static declaration.  This is the source of truth for capability counts,
-- scheduling and future Plan validation.
data ToolDefinition = ToolDefinition
  { tdRef :: !ToolRef,
    tdSchemaVersion :: !SchemaVersion,
    tdEffects :: !(Set ToolEffect),
    tdParallelism :: !ToolParallelism,
    tdRetryClass :: !ToolRetryClass,
    tdAuthorities :: !(Set ToolAuthority),
    -- | How long this tool may run before the kernel stops waiting.
    tdDeadline :: !ToolDeadline,
    -- | An audited promise that this tool performs no effect on any path that
    -- returns an error — argument checks, permission checks and lookups all
    -- happen before the first write or send.
    --
    -- It exists because the default is necessarily pessimistic.  A tool that
    -- writes or sends and then fails may have already done half of it, so its
    -- failure is reported as outcome-unknown, and the host prompt tells the
    -- model not to retry an outcome-unknown call.  That is right for a failure
    -- mid-effect and badly wrong for a rejected argument: the model cannot
    -- correct its own mistake, because it has been told it does not know
    -- whether the mistake took effect.
    --
    -- 'False' is the safe answer and the default.  Set it only after reading
    -- the tool and confirming every error path precedes every effect.
    tdFailuresPrecedeEffects :: !Bool
  }
  deriving stock (Show, Eq)

-- | Safe catalog view: all planning/diagnostic metadata, no executable
-- closure.  Description and schema come from the same registered tool that is
-- advertised to the model.
data CatalogTool = CatalogTool
  { ctDefinition :: !ToolDefinition,
    ctDescription :: !Text,
    ctSchema :: !Value,
    ctSchemaHash :: !SchemaHash
  }
  deriving stock (Show, Eq)

data RegisteredTool es = RegisteredTool
  { rtView :: !CatalogTool,
    rtRun :: Value -> Eff es (Either Text Value)
  }

newtype ToolCatalog es = ToolCatalog (Map ToolRef (RegisteredTool es))

instance Show (ToolCatalog es) where
  show = show . catalogTools

data ToolCatalogError
  = DuplicateToolDefinition !ToolRef
  | DuplicateToolRunner !ToolRef
  | MissingToolDefinition !ToolRef
  | MissingToolRunner !ToolRef
  | EmptyToolDescription !ToolRef
  | InvalidToolSchema !ToolRef !Text
  | InvalidToolMetadata !ToolRef !Text
  deriving stock (Show, Eq)

instance Exception ToolCatalogError

data ToolFault = ToolFault
  { tfCode :: !Text,
    tfMessage :: !Text,
    tfRetryClass :: !ToolRetryClass
  }
  deriving stock (Show, Eq)

-- | Normalised effect outcome.  Async cancellation never appears here:
-- 'trySync' rethrows it.  Legacy mutating runners that return an error or
-- throw are conservatively classified as outcome-unknown because the kernel
-- cannot prove whether they crossed their external effect boundary.
data ToolOutcome
  = ToolRejected !ToolFault
  | ToolFailedBeforeEffect !ToolFault
  | ToolSucceeded !Value
  | ToolCommitted !Value
  | ToolOutcomeUnknown !ToolFault
  deriving stock (Show, Eq)

catalogTools :: ToolCatalog es -> [CatalogTool]
catalogTools (ToolCatalog byRef) = map (.rtView) (Map.elems byRef)

buildToolCatalog :: [ToolDefinition] -> [Tool es] -> Either ToolCatalogError (ToolCatalog es)
buildToolCatalog definitions runners = do
  definitionsByRef <- uniqueDefinitions definitions
  runnersByRef <- uniqueRunners runners
  traverse_ (requireRunner runnersByRef) (Map.keys definitionsByRef)
  traverse_ (requireDefinition definitionsByRef) (Map.keys runnersByRef)
  registered <- traverseWithKeyEither (register runnersByRef) definitionsByRef
  pure (ToolCatalog registered)
  where
    register runnersByRef ref definition = do
      validateDefinition definition
      runner <- maybe (Left (MissingToolRunner ref)) Right (Map.lookup ref runnersByRef)
      if T.null (T.strip runner.toolDescription)
        then Left (EmptyToolDescription ref)
        else do
          validateSchema ref runner.toolSchema
          pure
            RegisteredTool
              { rtView =
                  CatalogTool
                    { ctDefinition = definition,
                      ctDescription = runner.toolDescription,
                      ctSchema = runner.toolSchema,
                      ctSchemaHash = schemaHash runner.toolSchema
                    },
                rtRun = runner.toolRun
              }

    requireRunner runnersByRef ref =
      if Map.member ref runnersByRef then Right () else Left (MissingToolRunner ref)
    requireDefinition definitionsByRef ref =
      if Map.member ref definitionsByRef then Right () else Left (MissingToolDefinition ref)

uniqueDefinitions :: [ToolDefinition] -> Either ToolCatalogError (Map ToolRef ToolDefinition)
uniqueDefinitions = foldlM insertOne Map.empty
  where
    insertOne acc definition
      | Map.member definition.tdRef acc = Left (DuplicateToolDefinition definition.tdRef)
      | otherwise = Right (Map.insert definition.tdRef definition acc)

uniqueRunners :: [Tool es] -> Either ToolCatalogError (Map ToolRef (Tool es))
uniqueRunners = foldlM insertOne Map.empty
  where
    insertOne acc runner =
      let ref = ToolRef runner.toolName
       in if Map.member ref acc
            then Left (DuplicateToolRunner ref)
            else Right (Map.insert ref runner acc)

validateDefinition :: ToolDefinition -> Either ToolCatalogError ()
validateDefinition definition
  | T.null (T.strip definition.tdRef.unToolRef) = bad "tool ref is blank"
  | definition.tdSchemaVersion.unSchemaVersion <= 0 = bad "schema version must be positive"
  | definition.tdDeadline.toolDeadlineSeconds <= 0 = bad "start-to-close deadline must be positive"
  | definition.tdParallelism == ParallelSafe && any isMutating definition.tdEffects =
      bad "mutating, sending, LLM, or reflective tools cannot declare ParallelSafe"
  | definition.tdRetryClass == RetrySafe && any isMutating definition.tdEffects =
      bad "mutating, sending, LLM, or reflective tools cannot declare RetrySafe"
  | otherwise = Right ()
  where
    bad = Left . InvalidToolMetadata definition.tdRef

isMutating :: ToolEffect -> Bool
isMutating EffectRead {} = False
isMutating _ = True

schemaHash :: Value -> SchemaHash
schemaHash =
  SchemaHash
    . TE.decodeUtf8
    . B16.encode
    . SHA256.hash
    . LBS.toStrict
    . encode

validateSchema :: ToolRef -> Value -> Either ToolCatalogError ()
validateSchema ref = \case
  Object schema -> do
    case KeyMap.lookup "type" schema of
      Just (String "object") -> Right ()
      _ -> invalid "root type must be object"
    properties <- case KeyMap.lookup "properties" schema of
      Nothing -> Right KeyMap.empty
      Just (Object p) -> Right p
      Just _ -> invalid "properties must be an object"
    required <- case KeyMap.lookup "required" schema of
      Nothing -> Right []
      Just (Array xs) -> traverse requiredName (toList xs)
      Just _ -> invalid "required must be an array of strings"
    traverse_ (validatePropertySchema ref) (KeyMap.toList properties)
    case find (not . (`KeyMap.member` properties) . Key.fromText) required of
      Nothing -> Right ()
      Just name -> invalid ("required property has no schema: " <> name)
  _ -> invalid "schema must be a JSON object"
  where
    invalid :: Text -> Either ToolCatalogError a
    invalid = Left . InvalidToolSchema ref
    requiredName (String name) = Right name
    requiredName _ = invalid "required must contain only strings"

validatePropertySchema :: ToolRef -> (Key.Key, Value) -> Either ToolCatalogError ()
validatePropertySchema ref (name, Object propertySchema) =
  case KeyMap.lookup "type" propertySchema of
    Nothing -> Right ()
    Just (String kind)
      | kind `elem` ["string", "integer", "number", "boolean", "object", "array"] -> Right ()
      | otherwise -> invalid ("unsupported type for " <> key <> ": " <> kind)
    Just _ -> invalid ("type for " <> key <> " must be a string")
  where
    key = Key.toText name
    invalid = Left . InvalidToolSchema ref
validatePropertySchema ref (name, _) =
  Left (InvalidToolSchema ref ("property schema must be an object: " <> Key.toText name))

validateArguments :: CatalogTool -> Value -> Either ToolFault ()
validateArguments view = \case
  Object args -> do
    let schema = case view.ctSchema of
          Object o -> o
          _ -> KeyMap.empty -- impossible after catalog validation
        properties = case KeyMap.lookup "properties" schema of
          Just (Object p) -> p
          _ -> KeyMap.empty
        required = case KeyMap.lookup "required" schema of
          Just (Array xs) -> [name | String name <- toList xs]
          _ -> []
    case find (not . (`KeyMap.member` args) . Key.fromText) required of
      Just name -> Left (rejectedFault view ("missing required property: " <> name))
      Nothing -> traverse_ (validatePresent args view) (KeyMap.toList properties)
  _ -> Left (rejectedFault view "arguments must be a JSON object")

validatePresent :: Object -> CatalogTool -> (Key.Key, Value) -> Either ToolFault ()
validatePresent args view (name, Object propertySchema) = case KeyMap.lookup name args of
  Nothing -> Right ()
  Just value -> do
    case KeyMap.lookup "type" propertySchema of
      Nothing -> Right ()
      Just (String kind)
        | valueHasType kind value -> Right ()
        | otherwise -> Left (rejectedFault view (Key.toText name <> " must be " <> kind))
      _ -> Right ()
    validateEnum value
    validateBounds value
  where
    validateEnum value = case KeyMap.lookup "enum" propertySchema of
      Just (Array allowed)
        | value `notElem` allowed ->
            Left (rejectedFault view (Key.toText name <> " is not an allowed value"))
      _ -> Right ()

    validateBounds (Number n) = do
      case KeyMap.lookup "minimum" propertySchema of
        Just (Number minimumValue)
          | n < minimumValue -> Left (rejectedFault view (Key.toText name <> " is below minimum"))
        _ -> Right ()
      case KeyMap.lookup "maximum" propertySchema of
        Just (Number maximumValue)
          | n > maximumValue -> Left (rejectedFault view (Key.toText name <> " is above maximum"))
        _ -> Right ()
    validateBounds _ = Right ()
validatePresent _ view (name, _) =
  Left (rejectedFault view ("invalid registered schema for " <> Key.toText name))

valueHasType :: Text -> Value -> Bool
valueHasType "string" String {} = True
valueHasType "integer" (Number n) = case floatingOrInteger @Double @Integer n of
  Right _ -> True
  Left _ -> False
valueHasType "number" Number {} = True
valueHasType "boolean" Bool {} = True
valueHasType "object" Object {} = True
valueHasType "array" Array {} = True
valueHasType _ _ = False

rejectedFault :: CatalogTool -> Text -> ToolFault
rejectedFault view message =
  ToolFault
    { tfCode = "invalid_arguments",
      tfMessage = message,
      tfRetryClass = view.ctDefinition.tdRetryClass
    }

toToolSpec :: RegisteredTool es -> ToolSpec
toToolSpec registered =
  ToolSpec
    { specName = registered.rtView.ctDefinition.tdRef.unToolRef,
      specDescription = registered.rtView.ctDescription,
      specSchema = registered.rtView.ctSchema
    }

--------------------------------------------------------------------------------
-- Effect.

data Tools :: Effect where
  ListToolSpecs :: Tools m [ToolSpec]
  ListCatalogTools :: Tools m [CatalogTool]
  InvokeTool :: Text -> Value -> Tools m ToolOutcome

type instance DispatchOf Tools = Dynamic

runTools ::
  forall es a.
  Concurrent :> es =>
  ToolCatalog es ->
  Eff (Tools : es) a ->
  Eff es a
runTools (ToolCatalog byRef) = interpret $ \_ -> \case
  ListToolSpecs -> pure (map toToolSpec (Map.elems byRef))
  ListCatalogTools -> pure (map (.rtView) (Map.elems byRef))
  InvokeTool name args -> case Map.lookup (ToolRef name) byRef of
    Nothing -> pure . ToolRejected $ ToolFault "unknown_tool" ("unknown tool: " <> name) RetrySafe
    Just registered -> case validateArguments registered.rtView args of
      Left fault -> pure (ToolRejected fault)
      Right () -> execute args registered
  where
    execute args registered = do
      attempted <- trySync (race (threadDelay deadlineMicros) (registered.rtRun args))
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
        Right (Right (Left message)) ->
          failure definition.tdFailuresPrecedeEffects "tool_error" message
        Right (Right (Right value))
          | hasCommitEffects definition -> ToolCommitted value
          | otherwise -> ToolSucceeded value
      where
        definition = registered.rtView.ctDefinition
        seconds = definition.tdDeadline.toolDeadlineSeconds
        deadlineMicros = seconds * 1_000_000
        failure precedesEffects code message =
          let fault = ToolFault code message definition.tdRetryClass
           in if hasCommitEffects definition && not precedesEffects
                then ToolOutcomeUnknown fault
                else ToolFailedBeforeEffect fault

hasCommitEffects :: ToolDefinition -> Bool
hasCommitEffects = any isCommitEffect . (.tdEffects)
  where
    isCommitEffect EffectWrite {} = True
    isCommitEffect EffectSend {} = True
    isCommitEffect _ = False

listToolSpecs :: Tools :> es => Eff es [ToolSpec]
listToolSpecs = send ListToolSpecs

listCatalogTools :: Tools :> es => Eff es [CatalogTool]
listCatalogTools = send ListCatalogTools

invokeTool :: Tools :> es => Text -> Value -> Eff es ToolOutcome
invokeTool name args = send (InvokeTool name args)

outcomeResult :: ToolOutcome -> Either Text Value
outcomeResult = \case
  ToolRejected fault -> Left fault.tfMessage
  ToolFailedBeforeEffect fault -> Left fault.tfMessage
  ToolSucceeded value -> Right value
  ToolCommitted value -> Right value
  ToolOutcomeUnknown fault -> Left (fault.tfMessage <> " (outcome unknown; not retried)")

traverseWithKeyEither :: (k -> a -> Either e b) -> Map k a -> Either e (Map k b)
traverseWithKeyEither f = Map.traverseWithKey f
