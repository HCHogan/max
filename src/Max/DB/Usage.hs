-- |
-- Postgres side of token accounting: the write 'Max.Effects.LLM' does
-- after every completed call, and the aggregates the admin API serves.
module Max.DB.Usage
  ( insertUsage,
    UsageDay (..),
    usageDaily,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (Day)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.LLM.Types (CallCost (..), TokenUsage (..))

-- | Record one completed call.  Callers guard against failure — a
-- lost accounting row must never fail the call it describes.
insertUsage ::
  (WithConnection :> es, IOE :> es) =>
  Maybe Int64 -> -- group served (Nothing = groupless work)
  Text -> -- source subsystem
  Text -> -- profile name
  TokenUsage ->
  Eff es ()
insertUsage gid source profile usage = do
  _ <-
    execute
      "INSERT INTO llm_usage (group_id, source, profile, prompt_tokens, completion_tokens, cached_prompt_tokens, cost, cost_currency) \
      \ VALUES (?,?,?,?,?,?,?,?)"
      (gid, source, profile, usage.usagePrompt, usage.usageCompletion, usage.usageCachedPrompt, (.amount) <$> usage.usageCost, (.currency) <$> usage.usageCost)
  pure ()

-- | One aggregate bucket of 'usageDaily': a (day, group, source,
-- profile) cell with its call count and token sums.
data UsageDay = UsageDay
  { udDay :: !Day,
    udGroup :: !(Maybe Int64),
    udSource :: !Text,
    udProfile :: !Text,
    udCalls :: !Int64,
    udPrompt :: !Int64,
    udCompletion :: !Int64,
    -- | Sum over rows that reported a cache split; rows that didn't
    -- contribute nothing (absent ≠ zero).
    udCachedPrompt :: !Int64,
    -- | Estimated cost of the bucket's priced calls. Buckets split by
    -- currency, so an unpriced bucket has neither.
    udCost :: !(Maybe Double),
    udCurrency :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

-- | Daily usage buckets for the last @days@ days.  Day boundaries are
-- taken in the configured display timezone (passed as a minute
-- offset — the config's zone is fixed-offset, no DST to honour), so
-- "today" on the dashboard matches "today" in the group.
usageDaily ::
  (WithConnection :> es, IOE :> es) =>
  Int -> -- timezone offset, minutes east of UTC
  Int -> -- how many days back
  Eff es [UsageDay]
usageDaily tzMinutes days = do
  rows <-
    query
      "SELECT (at + make_interval(mins => ?))::date AS day, \
      \       group_id, source, profile, \
      \       count(*), \
      \       sum(prompt_tokens)::bigint, \
      \       sum(completion_tokens)::bigint, \
      \       coalesce(sum(cached_prompt_tokens), 0)::bigint, \
      \       sum(cost), cost_currency \
      \  FROM llm_usage \
      \ WHERE at > now() - make_interval(days => ?) \
      \ GROUP BY 1, 2, 3, 4, cost_currency \
      \ ORDER BY 1 DESC, 2 NULLS LAST, 3, 4, cost_currency NULLS FIRST"
      (tzMinutes, days)
  pure
    [ UsageDay d g s p calls pr comp cach cost currency
    | (d, g, s, p, calls, pr, comp, cach, cost, currency) <- rows
    ]
