-- Issue #17, the claim primitive: one spelling for "is this lease free?"
--
-- Seven tables carry an owner/expiry pair and every one of them answered the
-- question differently.  Collected before this migration:
--
--   message_dispatches   lease_expires_at IS NULL OR lease_expires_at < now()
--   message_deliveries   lease_expires_at IS NULL OR lease_expires_at < now()
--   monitor_fires        claim_owner IS NULL OR claim_expires_at <= $client
--   plans                wake_owner IS NULL OR wake_claim_expires_at <= $client
--   episode_capture_runs status IN (...) AND lease_expires_at <= now()
--   maintenance_leases   expires_at <= now()          (plus a fencing token)
--   agent_turns          recovery_owner IS DISTINCT FROM $me   (no expiry)
--
-- Three axes drifted independently: whether a null owner or a null expiry is
-- what makes a row free, whether the boundary is @<@ or @<=@, and — the one
-- that can actually steal live work — whether "now" is the database's clock or
-- the caller's.  A worker whose clock runs fast reclaims a lease that has not
-- expired, and the two owners then run the same turn.
--
-- The union is stated once, here, so that a call site cannot get it subtly
-- wrong by writing it out again.
--
-- Scope: this migration fixes the *comparison*.  Setting the expiry is still
-- caller-computed in monitors and plans; moving that to max_lease_until is a
-- Haskell signature change and gets its own diff.

-- | Is this lease available to claim?
--
-- @owner IS NULL@ and @expires_at IS NULL@ are both accepted as free, which is
-- wider than any single call site was.  The state that motivates it is (owner
-- set, expiry null): a permanently held lease nobody can ever reclaim.  It is
-- not supposed to exist — every writer sets both or neither — but treating it
-- as held would let one bad write wedge a queue forever with no operator
-- recourse, and treating it as free costs nothing when the state is absent.
--
-- STABLE rather than IMMUTABLE: it reads the transaction clock, which is the
-- entire point.  PARALLEL SAFE so it does not disqualify a plan that would
-- otherwise parallelise the candidate scan.
CREATE FUNCTION max_lease_free(owner text, expires_at timestamptz)
  RETURNS boolean
  LANGUAGE sql
  STABLE
  PARALLEL SAFE
AS $$
  SELECT owner IS NULL OR expires_at IS NULL OR expires_at <= now()
$$;

COMMENT ON FUNCTION max_lease_free(text, timestamptz) IS
  'Issue #17: the one spelling of a free lease. Server clock, inclusive boundary, null owner or null expiry both count as free.';

-- | When a lease claimed now should expire.  Server clock by construction, so
-- a claim written through this can never disagree with 'max_lease_free' about
-- whose watch it is.
CREATE FUNCTION max_lease_until(seconds double precision)
  RETURNS timestamptz
  LANGUAGE sql
  STABLE
  PARALLEL SAFE
AS $$
  SELECT now() + make_interval(secs => seconds)
$$;

COMMENT ON FUNCTION max_lease_until(double precision) IS
  'Issue #17: expiry for a lease claimed now, on the same clock max_lease_free reads.';
