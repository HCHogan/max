-- ADR 007 runtime hardening: durable child contracts, exact plan grants,
-- durable cancellation, and fenced worker leases.

ALTER TABLE plans
  -- The exact name -> catalog fingerprint map admitted for the turn that
  -- opened the plan.  Children and resumed walks may only narrow this map.
  ADD COLUMN tool_grants jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(tool_grants) = 'object'),
  -- The enclosing goal whose budget/authority/schema admitted this plan.
  -- Historical plans remain nullable and resume under the migration's empty
  -- grant ceiling, so missing contract data narrows rather than widens them.
  ADD COLUMN root_goal jsonb
    CHECK (root_goal IS NULL OR jsonb_typeof(root_goal) = 'object'),
  -- Monotonic fencing token.  Every successful claim increments it; writes
  -- from a worker whose lease expired therefore cannot affect the new owner.
  ADD COLUMN wake_epoch bigint NOT NULL DEFAULT 0 CHECK (wake_epoch >= 0);

ALTER TABLE turn_edges
  -- A spawn child is reconstructible without consulting the parent model's
  -- transient stack frame.  Nullable only for pre-migration historical rows.
  ADD COLUMN child_goal jsonb
    CHECK (child_goal IS NULL OR jsonb_typeof(child_goal) = 'object'),
  ADD COLUMN child_view text,
  ADD COLUMN child_tool_grants jsonb
    CHECK (child_tool_grants IS NULL OR jsonb_typeof(child_tool_grants) = 'object'),
  ADD COLUMN child_inputs jsonb
    CHECK (child_inputs IS NULL OR jsonb_typeof(child_inputs) = 'array'),
  ADD COLUMN child_cancel_requested_at timestamptz,
  ADD COLUMN child_result_written_at timestamptz,
  ADD CONSTRAINT turn_edges_child_contract_kind_check
    CHECK ((child_goal IS NULL AND child_view IS NULL AND child_tool_grants IS NULL AND child_inputs IS NULL)
       OR edge_kind = 'spawn'),
  ADD CONSTRAINT turn_edges_child_contract_shape_check
    CHECK ((child_goal IS NULL) = (child_view IS NULL)
       AND (child_goal IS NULL) = (child_tool_grants IS NULL)
       AND (child_goal IS NULL) = (child_inputs IS NULL));

-- Pre-contract child results have no exact write timestamp. Preserve them and
-- establish the lifecycle invariant before validating it for later writes.
UPDATE turn_edges
SET child_result_written_at = now()
WHERE child_result IS NOT NULL AND child_result_written_at IS NULL;

ALTER TABLE turn_edges
  ADD CONSTRAINT turn_edges_child_result_time_check
    CHECK ((child_result IS NULL) = (child_result_written_at IS NULL)),
  ADD CONSTRAINT turn_edges_child_cancel_kind_check
    CHECK (child_cancel_requested_at IS NULL OR edge_kind = 'spawn');

-- Cancellation can be requested by a reconciler in another process.  Moving
-- the durable turn to a terminal state prevents boot recovery; the running
-- process also observes it at its next journal/model boundary.
CREATE FUNCTION max_notify_plan_child_cancelled() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.child_cancel_requested_at IS NOT NULL
     AND OLD.child_cancel_requested_at IS NULL THEN
    PERFORM pg_notify('max_plan_work', '1');
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER turn_edges_notify_plan_child_cancelled
  AFTER UPDATE OF child_cancel_requested_at ON turn_edges
  FOR EACH ROW EXECUTE FUNCTION max_notify_plan_child_cancelled();
