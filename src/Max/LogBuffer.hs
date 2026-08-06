-- |
-- A bounded in-memory tail of the log, so the admin panel can show
-- what the bot is doing without shelling out to journalctl.
--
-- __Why not a table.__  systemd already keeps the durable copy, with
-- rotation, compression and indexing that a hand-rolled @logs@ table
-- would only approximate.  Writing every line to Postgres as well is
-- pure write amplification for data that is already safe.  What the
-- journal cannot do is be read from a phone over the tailnet, and
-- that is the whole gap this closes — so the buffer holds the recent
-- past only, and says so.
--
-- Lost on restart by design.  A line that matters after a restart is
-- a line for @journalctl@.
module Max.LogBuffer
  ( LogBuffer,
    LogEntry (..),
    newLogBuffer,
    pushLog,
    queryLogs,
    countAtLeast,
    LogQuery (..),
    emptyQuery,
  )
where

import Control.Concurrent.STM
import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Int (Int64)
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Log (LogLevel (..), LogMessage (..))

-- | One captured line.  Mirrors @log-base@'s 'LogMessage' minus the
-- component, plus a monotonically increasing id so a polling client
-- can ask for "everything after what I already have" instead of
-- re-fetching and de-duplicating.
data LogEntry = LogEntry
  { leSeq :: !Int64,
    leAt :: !UTCTime,
    leLevel :: !LogLevel,
    leDomain :: !Text,
    leMessage :: !Text,
    leData :: !Value,
    -- | Message and rendered fields flattened once, lowercased, so
    -- text search doesn't re-render every entry on every query.
    leHaystack :: !Text
  }

-- | The ring plus the id counter.  One 'TVar' rather than two so a
-- reader never sees an entry whose id has been handed out but whose
-- row has not landed.
data LogBuffer = LogBuffer
  { lbEntries :: !(TVar (Seq LogEntry)),
    lbNext :: !(TVar Int64),
    lbCap :: !Int
  }

-- | How many lines to keep.  A busy dispatch prints on the order of
-- ten lines, so this is a few hundred dispatches — comfortably past
-- "what just happened", which is the question the panel answers.
newLogBuffer :: Int -> IO LogBuffer
newLogBuffer cap = LogBuffer <$> newTVarIO Seq.empty <*> newTVarIO 1 <*> pure (max 1 cap)

-- | Append one line, evicting the oldest when full.  Called from the
-- logger's emit callback, i.e. on every single log line: it must stay
-- cheap and must never throw.
pushLog :: LogBuffer -> LogMessage -> IO ()
pushLog buf msg = do
  let domain = T.intercalate "/" msg.lmDomain
      entry n =
        LogEntry
          { leSeq = n,
            leAt = msg.lmTime,
            leLevel = msg.lmLevel,
            leDomain = domain,
            leMessage = msg.lmMessage,
            leData = msg.lmData,
            leHaystack = T.toLower (T.unwords [domain, msg.lmMessage, flatten msg.lmData])
          }
  atomically $ do
    n <- readTVar buf.lbNext
    writeTVar buf.lbNext (n + 1)
    modifyTVar' buf.lbEntries $ \s ->
      let s' = s |> entry n
       in if Seq.length s' > buf.lbCap then Seq.drop (Seq.length s' - buf.lbCap) s' else s'

-- | @key=value@ text for the search haystack.  Deliberately not the
-- pretty renderer from "Max.Log": that one exists to be read at a
-- terminal (ANSI, padding, quoting) and none of that helps a
-- substring match.
flatten :: Value -> Text
flatten = \case
  Object o -> T.unwords [Key.toText k <> "=" <> scalar v | (k, v) <- KM.toList o]
  v -> scalar v
  where
    scalar = \case
      String s -> s
      Number n -> T.pack (show n)
      Bool b -> if b then "true" else "false"
      Null -> "null"
      Object o -> T.unwords [Key.toText k <> "=" <> scalar v | (k, v) <- KM.toList o]
      Array a -> T.unwords (map scalar (foldr (:) [] a))

-- | Filters the panel offers.  All are conjunctive; an unset field
-- matches everything.
data LogQuery = LogQuery
  { lqMinLevel :: !(Maybe LogLevel),
    -- | Exact domain match ("llm", "intent") — the usual first cut.
    lqDomain :: !(Maybe Text),
    -- | Case-insensitive substring over message + fields.
    lqSearch :: !(Maybe Text),
    -- | Only entries newer than this sequence number (for tailing).
    lqAfter :: !(Maybe Int64),
    lqLimit :: !Int
  }

emptyQuery :: LogQuery
emptyQuery =
  LogQuery
    { lqMinLevel = Nothing,
      lqDomain = Nothing,
      lqSearch = Nothing,
      lqAfter = Nothing,
      lqLimit = 200
    }

-- | How many buffered lines are at least this severe.
--
-- A count, not a page: 'queryLogs' truncates at 'lqLimit', so asking
-- it "how many warnings" gives the limit back once there are more
-- than that.  A badge needs the real number.
countAtLeast :: LogBuffer -> LogLevel -> IO Int
countAtLeast buf level = do
  entries <- readTVarIO buf.lbEntries
  pure (Seq.length (Seq.filter ((>= rank level) . rank . leLevel) entries))
  where
    rank :: LogLevel -> Int
    rank = \case
      LogTrace -> 0
      LogInfo -> 1
      LogAttention -> 2

-- | Newest-first, capped at 'lqLimit'.  Newest-first because that is
-- the order the question is asked in ("what just happened"), and it
-- keeps the limit meaningful when a filter matches thousands.
queryLogs :: LogBuffer -> LogQuery -> IO [LogEntry]
queryLogs buf q = do
  entries <- readTVarIO buf.lbEntries
  pure . take q.lqLimit . reverse . foldr (:) [] $ Seq.filter keep entries
  where
    keep e =
      maybe True (\l -> rank e.leLevel >= rank l) q.lqMinLevel
        && maybe True (== e.leDomain) q.lqDomain
        && maybe True ((`T.isInfixOf` e.leHaystack) . T.toLower) q.lqSearch
        && maybe True (< e.leSeq) q.lqAfter
    rank :: LogLevel -> Int
    rank = \case
      LogTrace -> 0
      LogInfo -> 1
      LogAttention -> 2
