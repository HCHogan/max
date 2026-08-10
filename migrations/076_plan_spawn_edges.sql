-- ADR 007 step 4: the actual side of reconciliation.
--
-- ADR 002 reserved turn_edges for spawn, depend and fork-from and shipped only
-- fork-from.  A plan's Fork emits the first of those, which makes this table
-- load-bearing rather than provenance-only: the reconciler's "which children
-- are running" is a query over it, diffed against the open goals of the plan
-- head.
--
-- Only 'spawn' is added.  'depend' is a cross-plan edge with no writer yet, and
-- an enum value nothing can produce reads to a maintainer as a capability that
-- exists.
ALTER TABLE turn_edges
  DROP CONSTRAINT turn_edges_edge_kind_check;

ALTER TABLE turn_edges
  ADD CONSTRAINT turn_edges_edge_kind_check
    CHECK (edge_kind IN ('fork-from', 'spawn'));

ALTER TABLE turn_edges
  -- Which plan's fork opened this child.  Carried rather than derived from
  -- from_turn_id: a nested fork's parent is a child turn, so root_turn_id does
  -- not identify the plan a grandchild belongs to.
  ADD COLUMN plan_id bigint,
  -- The subgoal this child is serving, by content.  The reconciler's key: a
  -- plan edited between dispatch and now is diffed by what the work *is*, not
  -- by where it sat.
  ADD COLUMN goal_hash text,
  -- Where it sat when it was dispatched.  Journal provenance, deliberately not
  -- the identity: an edit that moves a goal must not orphan the child running
  -- it.
  ADD COLUMN dispatched_node_id text,
  ADD CONSTRAINT turn_edges_spawn_scope_fk
    FOREIGN KEY (plan_id, conversation_id)
    REFERENCES plans(plan_id, conversation_id) ON DELETE CASCADE,
  ADD CONSTRAINT turn_edges_goal_hash_check
    CHECK (goal_hash IS NULL OR goal_hash ~ '^[0-9a-f]{64}$'),
  ADD CONSTRAINT turn_edges_spawn_shape_check
    CHECK ((edge_kind = 'spawn')
      = (plan_id IS NOT NULL AND goal_hash IS NOT NULL AND dispatched_node_id IS NOT NULL));

-- A turn has at most one parent.  Without this a retry that re-recorded an
-- edge would double-count a running child and the reconciler would stop one of
-- them at random.
CREATE UNIQUE INDEX turn_edges_spawn_child_idx
  ON turn_edges (to_turn_id)
  WHERE edge_kind = 'spawn';

CREATE INDEX turn_edges_spawn_plan_idx
  ON turn_edges (plan_id, edge_id)
  WHERE edge_kind = 'spawn';
