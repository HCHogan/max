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
import Max.Schema (Schema)
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
data ToolCallMode = WorkCall | CheckpointCall deriving stock (Show, Eq, Ord)

data ToolParallelism
  = ParallelSafe
  | -- | Audited independent calls may write; callers order shared resources.
    ParallelIndependent
  | SequentialOnly
  deriving stock (Show, Eq, Ord)

data ToolRetryClass
  = RetrySafe
  | RetryIdempotent
  | RetryUnsafe
  deriving stock (Show, Eq, Ord)

-- | Per-call execution deadline in seconds. A timeout ends one tool call;
-- the turn's separate silence watchdog cancels the entire turn.
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
    -- | Historical catalog fingerprint field. Retained so grants and pinned
    -- workflows keep their identity; execution classification comes exclusively
    -- from ToolRunner results and never trusts this compatibility bit.
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
    ctSchema :: !Schema,
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
