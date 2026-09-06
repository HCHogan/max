{-# LANGUAGE TypeFamilies #-}

-- | Read a result handle through its bound conversation and clear boundary.
-- Blob digests, host paths and raw SQL are interpreter-only capabilities.
module Max.Effects.TurnQuery (TurnQuery, resolveTurnResult, expandTurnTrace, runTurnQuery) where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope)
import Max.DB.AgentTurn (resolveJournalResultValue)
import Max.DB.Transaction (withReadSnapshot)
import Max.DB.TurnContinuity qualified as DB
import Max.Effects.Blob (Blob)
import Max.Turn.Types (TurnOrdinal)

data TurnQuery :: Effect where
  ResolveTurnResult :: Text -> TurnQuery m (Maybe Value)
  ExpandTurnTrace :: TurnOrdinal -> Maybe Int64 -> Int -> TurnQuery m (Maybe Value)

type instance DispatchOf TurnQuery = Dynamic

resolveTurnResult :: (TurnQuery :> es) => Text -> Eff es (Maybe Value)
resolveTurnResult = send . ResolveTurnResult

expandTurnTrace :: (TurnQuery :> es) => TurnOrdinal -> Maybe Int64 -> Int -> Eff es (Maybe Value)
expandTurnTrace ordinal after limit = send (ExpandTurnTrace ordinal after limit)

runTurnQuery :: (WithConnection :> es, Blob :> es, IOE :> es) => ConversationScope -> Maybe UTCTime -> Eff (TurnQuery : es) a -> Eff es a
runTurnQuery scope cleared = interpret $ \_ -> \case
  ResolveTurnResult handle -> resolveJournalResultValue scope cleared handle
  ExpandTurnTrace ordinal after limit -> withReadSnapshot (DB.expandTurnTrace scope cleared ordinal after limit)
