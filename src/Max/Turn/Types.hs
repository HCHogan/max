-- | Small types shared by the durable turn store, task runtime, tools and
-- outbound boundary.  This module contains no database operations, keeping
-- the identity usable by the in-memory Agent tests.
module Max.Turn.Types
  ( AgentTurnId (..),
    TurnOrdinal (..),
    ExecutionOrdinal (..),
    AgentTurnRef (..),
    TurnOutputLink (..),
    TurnOutputContext,
    newTurnOutputContext,
    newTurnOutputContextAt,
    nextTurnOutputLink,
    turnOutputAgentTurn,
    turnHandleText,
    resultHandleText,
    ParsedTurnHandle (..),
    parseTurnHandle,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.ToField (ToField)
import Text.Read (readMaybe)

newtype AgentTurnId = AgentTurnId {unAgentTurnId :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

newtype TurnOrdinal = TurnOrdinal {unTurnOrdinal :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

newtype ExecutionOrdinal = ExecutionOrdinal {unExecutionOrdinal :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

data AgentTurnRef = AgentTurnRef
  { atrTurnId :: !AgentTurnId,
    atrTurnOrdinal :: !TurnOrdinal
  }
  deriving stock (Show, Eq, Ord)

data TurnOutputLink = TurnOutputLink
  { tolTurnId :: !AgentTurnId,
    tolChunkIndex :: !Int
  }
  deriving stock (Show, Eq, Ord)

-- | Shared monotonic allocator for every visible output path in one turn:
-- progress, debug, streamed/final reply, and visible-output tools.
data TurnOutputContext = TurnOutputContext
  { tocTurnRef :: !AgentTurnRef,
    tocNextChunk :: !(TVar Int)
  }

instance Show TurnOutputContext where
  show ctx = "TurnOutputContext " <> show ctx.tocTurnRef

instance Eq TurnOutputContext where
  left == right = left.tocTurnRef == right.tocTurnRef && left.tocNextChunk == right.tocNextChunk

newTurnOutputContext :: AgentTurnRef -> IO TurnOutputContext
newTurnOutputContext ref = newTurnOutputContextAt ref 0

-- | Re-open an existing turn after restart at the first chunk not already
-- committed to the canonical ledger.  The seed is host-derived from the
-- ledger; model input can never choose it.
newTurnOutputContextAt :: AgentTurnRef -> Int -> IO TurnOutputContext
newTurnOutputContextAt ref firstChunk =
  TurnOutputContext ref <$> newTVarIO (max 0 firstChunk)

-- | Allocate before publication.  A failed publication leaves a gap, which is
-- preferable to reusing an identity whose external outcome may be unknown.
nextTurnOutputLink :: TurnOutputContext -> IO TurnOutputLink
nextTurnOutputLink ctx = atomically $ do
  next <- readTVar ctx.tocNextChunk
  writeTVar ctx.tocNextChunk (next + 1)
  pure (TurnOutputLink ctx.tocTurnRef.atrTurnId next)

turnOutputAgentTurn :: TurnOutputContext -> AgentTurnRef
turnOutputAgentTurn = (.tocTurnRef)

turnHandleText :: TurnOrdinal -> Text
turnHandleText (TurnOrdinal ordinal) = "t#" <> T.pack (show ordinal)

resultHandleText :: TurnOrdinal -> ExecutionOrdinal -> Text
resultHandleText turn execution =
  turnHandleText turn <> ":r" <> T.pack (show execution.unExecutionOrdinal)

data ParsedTurnHandle
  = ParsedTurn !TurnOrdinal
  | ParsedTurnResult !TurnOrdinal !ExecutionOrdinal
  deriving stock (Show, Eq)

-- | Accept the exact scoped runtime grammar, with optional surrounding
-- whitespace.  Bare integers and internal journal ids are intentionally not
-- aliases: handles are explicit syntax, not ambient authority.
parseTurnHandle :: Text -> Maybe ParsedTurnHandle
parseTurnHandle raw = do
  rest <- T.stripPrefix "t#" (T.strip raw)
  case T.breakOn ":r" rest of
    (turnText, resultText)
      | T.null resultText -> ParsedTurn <$> positiveTurn turnText
      | otherwise -> do
          turn <- positiveTurn turnText
          result <- positiveExecution =<< T.stripPrefix ":r" resultText
          pure (ParsedTurnResult turn result)
  where
    positiveTurn text = do
      value <- readMaybe (T.unpack text)
      if value > 0 then Just (TurnOrdinal value) else Nothing
    positiveExecution text = do
      value <- readMaybe (T.unpack text)
      if value > 0 then Just (ExecutionOrdinal value) else Nothing
