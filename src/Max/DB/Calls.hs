-- |
-- Postgres side of the LLM call log: the write "Max.Effects.LLM" does
-- after every call, the two reads the admin panel serves, and the
-- pruner that keeps the table from growing without bound.
--
-- See @migrations/031_llm_calls.sql@ for why the bodies live here
-- rather than on @llm_usage@.
module Max.DB.Calls
  ( CallRow (..),
    CallDetail (..),
    insertCall,
    listCalls,
    fetchCall,
    pruneCalls,
    redactDataUrls,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), (:.) (..))
import Database.PostgreSQL.Simple.ToField (ToField (..), toJSONField)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb v) = toJSONField v

-- | One row as the list view needs it: everything except the bodies,
-- which are megabytes in aggregate and are fetched per-row on demand.
-- @reqBytes@/@respBytes@ come from the database so the list can show
-- how big a call was without shipping it.
data CallRow = CallRow
  { crId :: !Int64,
    crAt :: !UTCTime,
    crGroup :: !(Maybe Int64),
    crSource :: !Text,
    crProfile :: !Text,
    crModel :: !Text,
    crStreamed :: !Bool,
    crDurationMs :: !Int,
    crError :: !(Maybe Text),
    crPrompt :: !(Maybe Int),
    crCompletion :: !(Maybe Int),
    crCached :: !(Maybe Int),
    crReqBytes :: !Int,
    crRespBytes :: !Int
  }
  deriving stock (Show, Eq)

-- | A row plus its bodies.
data CallDetail = CallDetail
  { cdRow :: !CallRow,
    cdRequest :: !Value,
    cdResponse :: !(Maybe Value)
  }

-- | Record one completed call.  Callers guard against failure — a
-- lost audit row must never fail the call it describes.
insertCall ::
  (WithConnection :> es, IOE :> es) =>
  Maybe Int64 -> -- group served
  Text -> -- source subsystem
  Text -> -- profile name
  Text -> -- wire model id
  Bool -> -- streamed?
  Int -> -- duration, ms
  Value -> -- request body (already redacted)
  Maybe Value -> -- response, absent on failure
  Maybe Text -> -- error, absent on success
  Maybe (Int, Int, Maybe Int) -> -- (prompt, completion, cached) tokens
  Eff es ()
insertCall gid source profile model streamed ms req resp err usage = do
  _ <-
    execute
      "INSERT INTO llm_calls \
      \ (group_id, source, profile, model, streamed, duration_ms, request, response, error, \
      \  prompt_tokens, completion_tokens, cached_prompt_tokens) \
      \ VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
      ( (gid, source, profile, model, streamed, ms)
          :. (Jsonb req, Jsonb <$> resp, err)
          :. ( fmap (\(p, _, _) -> p) usage,
               fmap (\(_, c, _) -> c) usage,
               usage >>= \(_, _, k) -> k
             )
      )
  pure ()

-- | Newest-first page of calls.  Every filter is optional and
-- conjunctive; @before@ pages by id rather than offset so a call
-- landing mid-scroll can't shift the page under you.
listCalls ::
  (WithConnection :> es, IOE :> es) =>
  Maybe Int64 -> -- group
  Maybe Text -> -- source
  Bool -> -- failures only
  Maybe Int64 -> -- id to page back from
  Int -> -- limit
  Eff es [CallRow]
listCalls mGid mSource failedOnly mBefore lim = do
  rows <-
    query
      "SELECT id, at, group_id, source, profile, model, streamed, duration_ms, error, \
      \       prompt_tokens, completion_tokens, cached_prompt_tokens, \
      \       pg_column_size(request), coalesce(pg_column_size(response), 0) \
      \  FROM llm_calls \
      \ WHERE (?::bigint IS NULL OR group_id = ?) \
      \   AND (?::text   IS NULL OR source   = ?) \
      \   AND (NOT ?::boolean OR error IS NOT NULL) \
      \   AND (?::bigint IS NULL OR id < ?) \
      \ ORDER BY id DESC LIMIT ?"
      ((mGid, mGid, mSource, mSource) :. (failedOnly, mBefore, mBefore, lim))
  pure
    [ CallRow i at g s p m st d e pt ct kt rb sb
    | (i, at, g, s, p, m, st, d) :. (e, pt, ct, kt, rb, sb) <- rows
    ]

-- | One call with its bodies.
fetchCall :: (WithConnection :> es, IOE :> es) => Int64 -> Eff es (Maybe CallDetail)
fetchCall cid = do
  rows <-
    query
      "SELECT id, at, group_id, source, profile, model, streamed, duration_ms, error, \
      \       prompt_tokens, completion_tokens, cached_prompt_tokens, \
      \       pg_column_size(request), coalesce(pg_column_size(response), 0), \
      \       request, response \
      \  FROM llm_calls WHERE id = ?"
      (Only cid)
  pure $ case rows of
    ((i, at, g, s, p, m, st, d) :. (e, pt, ct, kt, rb, sb) :. (req, resp)) : _ ->
      Just (CallDetail (CallRow i at g s p m st d e pt ct kt rb sb) req resp)
    [] -> Nothing

-- | Drop bodies older than @days@.  Returns how many rows went, for
-- the log line.
pruneCalls :: (WithConnection :> es, IOE :> es) => Int -> Eff es Int64
pruneCalls days =
  execute "DELETE FROM llm_calls WHERE at < now() - make_interval(days => ?)" (Only days)

--------------------------------------------------------------------------------

-- | Replace every base64 data URL anywhere in a JSON value with a
-- placeholder naming its mime type and size.
--
-- This is what keeps the table small enough to be worth having: one
-- multimodal turn carries images at a megabyte apiece, and none of
-- those bytes answer the question the table exists for.  The shape of
-- the message is preserved exactly — the block is still an image
-- block at the same position, it just says how big the picture was
-- instead of being it.
redactDataUrls :: Value -> Value
redactDataUrls = go
  where
    go = \case
      String s -> String (redact s)
      Array a -> Array (fmap go a)
      Object o -> Object (fmap go o)
      v -> v
    redact s = case T.breakOn ";base64," s of
      (before, rest)
        | T.null rest -> s
        | not ("data:" `T.isPrefixOf` before) -> s
        | otherwise ->
            let payload = T.drop 8 rest
             in before <> ";base64,…(" <> T.pack (show (T.length payload)) <> " chars)"
