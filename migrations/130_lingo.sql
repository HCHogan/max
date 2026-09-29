-- Group lingo learned from settled conversation history: how members phrase
-- things (expressions) and the terms that need this group's context to
-- understand (jargon). Rows are statistics over the immutable ledger, not
-- facts about anyone; the "lingo" conversation cursor records how far the
-- learner has read, so resetting it relearns from the beginning.
CREATE TABLE lingo_expressions (
  id bigserial PRIMARY KEY,
  conversation_id bigint NOT NULL,
  situation text NOT NULL CHECK (btrim(situation) <> ''),
  style text NOT NULL CHECK (btrim(style) <> ''),
  style_key text NOT NULL CHECK (style_key <> ''),
  hits integer NOT NULL DEFAULT 1 CHECK (hits > 0),
  example_message_id bigint NOT NULL,
  example_text text NOT NULL,
  first_learned_at timestamptz NOT NULL DEFAULT now(),
  last_learned_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (conversation_id, style_key)
);

CREATE INDEX lingo_expressions_rank_idx ON lingo_expressions (conversation_id, hits DESC, last_learned_at DESC);

-- A term is only injected into prompts after inference found a meaning that
-- differs from its context-free reading (group_specific). Speakers and
-- contexts are bounded samples that feed that inference.
CREATE TABLE lingo_jargon (
  id bigserial PRIMARY KEY,
  conversation_id bigint NOT NULL,
  term text NOT NULL CHECK (btrim(term) <> ''),
  term_key text NOT NULL CHECK (term_key <> ''),
  hits integer NOT NULL DEFAULT 1 CHECK (hits > 0),
  speakers bigint[] NOT NULL DEFAULT '{}',
  contexts text[] NOT NULL DEFAULT '{}',
  example_message_id bigint NOT NULL,
  example_text text NOT NULL,
  meaning text CHECK (meaning IS NULL OR btrim(meaning) <> ''),
  group_specific boolean NOT NULL DEFAULT false,
  inferred_hits integer NOT NULL DEFAULT 0 CHECK (inferred_hits >= 0),
  first_learned_at timestamptz NOT NULL DEFAULT now(),
  last_learned_at timestamptz NOT NULL DEFAULT now(),
  inferred_at timestamptz,
  UNIQUE (conversation_id, term_key),
  CHECK (NOT group_specific OR meaning IS NOT NULL)
);

CREATE INDEX lingo_jargon_known_idx ON lingo_jargon (conversation_id, hits DESC) WHERE group_specific;
