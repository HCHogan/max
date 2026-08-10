-- ADR 007 step 3: a plan is a durable object, not a value inside a running
-- dispatch.
--
-- The shape follows the ADR's storage rule — history is append-only, intent is
-- a value.  `plan_revisions` is the append-only half: every version a plan ever
-- had, with what caused it.  `plans` is the mutable half, and it holds no
-- document of its own; `head_revision` names the revision that is current.  A
-- steer, a filled hole, and a completed child all append a row and move the
-- pointer, so "what did this plan look like when that child was dispatched" is
-- a query rather than a lost intermediate state.
--
-- `head_revision` doubles as the optimistic-concurrency token.  Three writers
-- act on one plan while children run — the front model, the user, and children
-- reporting results — and none of them may clobber a version they did not read.
CREATE TABLE plans (
  plan_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  conversation_id bigint NOT NULL
    REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  plan_ordinal bigint NOT NULL CHECK (plan_ordinal > 0),
  -- The turn this plan was opened for.  A plan outlives any single elaboration
  -- round but never leaves the turn that owns it.
  root_turn_id bigint NOT NULL,
  head_revision integer NOT NULL DEFAULT 1 CHECK (head_revision > 0),
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'done', 'abandoned')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  closed_at timestamptz,
  CONSTRAINT plans_ordinal_unique UNIQUE (conversation_id, plan_ordinal),
  -- Composite key so later tables (turn_edges gaining a spawn kind, ADR 007
  -- step 4) can carry a scoped foreign key rather than trusting a bare id.
  CONSTRAINT plans_scope_unique UNIQUE (plan_id, conversation_id),
  CONSTRAINT plans_root_turn_scope_fk
    FOREIGN KEY (root_turn_id, conversation_id)
    REFERENCES agent_turns(turn_id, conversation_id) ON DELETE CASCADE,
  CONSTRAINT plans_closed_at_check
    CHECK ((status = 'open') = (closed_at IS NULL))
);

CREATE INDEX plans_open_idx
  ON plans (conversation_id, plan_id)
  WHERE status = 'open';

CREATE INDEX plans_root_turn_idx
  ON plans (root_turn_id);

-- Append-only.  There is no UPDATE path: a revision records what the plan was,
-- and rewriting one would erase the causal record the reconciler and the
-- narrator both read.
CREATE TABLE plan_revisions (
  plan_id bigint NOT NULL REFERENCES plans(plan_id) ON DELETE CASCADE,
  revision integer NOT NULL CHECK (revision > 0),
  -- Stored beside the document so a plan written by a newer binary is found by
  -- a query rather than by a decode failure at read time.
  ir_version integer NOT NULL CHECK (ir_version > 0),
  plan_hash text NOT NULL CHECK (plan_hash ~ '^[0-9a-f]{64}$'),
  document jsonb NOT NULL CHECK (jsonb_typeof(document) = 'object'),
  cause text NOT NULL
    CHECK (cause IN ('initial', 'elaboration', 'steer', 'child', 'rehole')),
  -- Who moved it.  A steer names a human; an elaboration or a child completion
  -- names neither, and saying so is the difference between "the group did this"
  -- and "the machine did this".
  caused_by_principal_id bigint
    REFERENCES principals(principal_id) ON DELETE SET NULL,
  caused_by_turn_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (plan_id, revision),
  CONSTRAINT plan_revisions_initial_check
    CHECK ((revision = 1) = (cause = 'initial'))
);

CREATE INDEX plan_revisions_history_idx
  ON plan_revisions (plan_id, created_at DESC);
