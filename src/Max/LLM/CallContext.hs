-- | Attribution and observer contracts for a model call, independent of the
-- completion effect and its protocol implementation.
module Max.LLM.CallContext (ChatCtx (..), UsageWriter, CallRecord (..), CallWriter) where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Text (Text)
import Max.LLM.Types (TokenUsage)
import Max.RuntimeConfig (ConfigGeneration)
import Max.Turn.Types (AgentTurnId)

-- | Who a chat call is for, threaded through every 'Chat' /
-- 'ChatStreaming' op so the interpreter can persist token usage with
-- attribution. Attribution is an explicit call parameter so every caller
-- declares its source and optional durable ownership.
data ChatCtx = ChatCtx
  { -- | Which subsystem is spending: @turn@ \/ @wrapup@ \/ @intent@ \/
    -- @supplement@ \/ @historian@ \/ @memory-dream@ \/ @caption@.
    ccSource :: !Text,
    -- | The group the call serves; 'Nothing' for groupless work
    -- (caption workers run against a shared library).
    ccGroup :: !(Maybe Int64),
    -- | Per-call reasoning-effort override (the @!effort@ session
    -- override, threaded in by the agent turn).  'Nothing' = the
    -- profile's configured 'LLMProfile.effort'.  On 'ChatCtx' rather
    -- than a new @chat@ parameter so background workers keep their
    -- profiles' own settings without every call site changing shape.
    ccEffort :: !(Maybe Text),
    -- | Per-call wall-clock timeout override.  Background jobs whose
    -- completion latency differs materially from interactive turns can share
    -- a model profile without inheriting its interactive timeout.
    ccTimeoutSeconds :: !(Maybe Int),
    -- | Per-call retry schedule for buffered HTTP requests.  'Nothing' uses
    -- the normal shallow transport retries; @Just []@ makes exactly one HTTP
    -- attempt.  Durable workers use the latter because their persisted queue,
    -- not an invisible transport loop, owns retry timing and fairness.
    ccBufferedRetryDelaysSeconds :: !(Maybe [Int]),
    -- | Durable agent attribution.  Background/model-router calls leave it
    -- empty; every call inside a production turn carries it.
    ccAgentTurnId :: !(Maybe AgentTurnId),
    -- | Immutable runtime generation held by an agent dispatch. Background
    -- calls use 'Nothing' and resolve the current generation at call start.
    ccConfigGeneration :: !(Maybe ConfigGeneration)
  }
  deriving stock (Show, Eq)

-- | Where the interpreter reports usage after each completed call.
-- Plain IO so stacks without a database (the intent-eval harness,
-- tests) can pass @\\_ _ _ -> pure ()@ instead of growing a
-- 'WithConnection' constraint they can't satisfy.
type UsageWriter = ChatCtx -> Text -> TokenUsage -> IO ()

-- | Everything one call did, handed to 'CallWriter' whether it
-- succeeded or not — a failed call is exactly the one you want the
-- request body of, and until this existed it left only a log line.
data CallRecord = CallRecord
  { crCtx :: !ChatCtx,
    crProfile :: !Text,
    crModel :: !Text,
    crStreamed :: !Bool,
    crDurationMs :: !Int,
    -- | The JSON body as sent. Persistence sinks apply their own redaction.
    crRequest :: !Value,
    crResponse :: !(Maybe Value),
    crError :: !(Maybe Text),
    crUsage :: !(Maybe TokenUsage)
  }

-- | Sink for the full request/response log.  Same plain-IO shape and
-- same reason as 'UsageWriter'.
type CallWriter = CallRecord -> IO ()
