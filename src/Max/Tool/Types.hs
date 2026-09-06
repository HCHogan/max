-- | Tool protocol and host-owned metadata, independent of execution.
module Max.Tool.Types
  ( ToolSpec (..),
    ToolRef (..),
    SchemaVersion (..),
    SchemaHash (..),
    ToolEffect (..),
    ToolParallelism (..),
    ToolCallMode (..),
    ToolRetryClass (..),
    ToolAuthority (..),
    ToolDeadline (..),
    ToolDefinition (..),
    CatalogTool (..),
    ToolCatalogError (..),
    ToolFault (..),
    ToolOutcome (..),
    ToolInvocation (..),
  )
where

import Control.Exception (Exception)
import Data.Aeson (Value)
import Data.Set (Set)
import Data.Text (Text)
import Max.Tool.Control (LoopControl)

-- | Model-facing tool description and JSON argument schema.
data ToolSpec = ToolSpec
  { specName :: !Text,
    specDescription :: !Text,
    specSchema :: !Value
  }
  deriving stock (Show)

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

-- | Checkpoints do not spend work budget; finish calls are exclusive in a round.
data ToolCallMode = WorkCall | CheckpointCall | FinishCall deriving stock (Show, Eq, Ord)

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
    tdFailuresPrecedeEffects :: !Bool,
    tdCallMode :: !ToolCallMode
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

-- | Separate host control from the model-visible outcome.
data ToolInvocation = ToolInvocation {tiOutcome :: !ToolOutcome, tiControl :: !LoopControl}
  deriving stock (Show, Eq)
