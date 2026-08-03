-- Canonical multi-platform identity, source-event, and delivery ledger.
--
-- The legacy bigint columns remain populated while QQ is cut over.  They are
-- compatibility projections only: native ids are scoped by explicit accounts
-- and endpoints, and routing/authorization must use the canonical keys below.

CREATE TABLE platform_accounts (
  platform_account_id bigserial PRIMARY KEY,
  platform text NOT NULL CHECK (platform <> ''),
  native_account_id text NOT NULL CHECK (native_account_id <> ''),
  display_name text,
  capabilities jsonb NOT NULL DEFAULT '{}'::jsonb,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (platform, native_account_id)
);

CREATE TABLE conversations (
  conversation_id bigserial PRIMARY KEY,
  conversation_kind text NOT NULL CHECK (conversation_kind IN ('group', 'direct')),
  title text,
  legacy_group_id bigint UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE conversation_endpoints (
  endpoint_id bigserial PRIMARY KEY,
  conversation_id bigint NOT NULL REFERENCES conversations(conversation_id) ON DELETE CASCADE,
  platform_account_id bigint NOT NULL REFERENCES platform_accounts(platform_account_id) ON DELETE RESTRICT,
  native_conversation_id text NOT NULL CHECK (native_conversation_id <> ''),
  endpoint_kind text NOT NULL CHECK (endpoint_kind IN ('group', 'direct')),
  endpoint_mode text NOT NULL DEFAULT 'standalone' CHECK (endpoint_mode IN ('standalone', 'mirror')),
  display_name text,
  enabled boolean NOT NULL DEFAULT true,
  capabilities jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (platform_account_id, native_conversation_id)
);

CREATE INDEX conversation_endpoints_conversation_idx
  ON conversation_endpoints (conversation_id, enabled);

CREATE TABLE principals (
  principal_id bigserial PRIMARY KEY,
  display_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE principal_identities (
  principal_identity_id bigserial PRIMARY KEY,
  principal_id bigint NOT NULL REFERENCES principals(principal_id) ON DELETE CASCADE,
  platform_account_id bigint NOT NULL REFERENCES platform_accounts(platform_account_id) ON DELETE CASCADE,
  native_user_id text NOT NULL CHECK (native_user_id <> ''),
  display_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (platform_account_id, native_user_id)
);

CREATE INDEX principal_identities_principal_idx
  ON principal_identities (principal_id);

CREATE SEQUENCE canonical_message_id_seq AS bigint;

ALTER TABLE messages
  ADD COLUMN canonical_message_id bigint,
  ADD COLUMN canonical_content jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN conversation_id bigint REFERENCES conversations(conversation_id) ON DELETE RESTRICT,
  ADD COLUMN conversation_seq bigint,
  ADD COLUMN author_principal_id bigint REFERENCES principals(principal_id) ON DELETE RESTRICT,
  ADD COLUMN origin_endpoint_id bigint REFERENCES conversation_endpoints(endpoint_id) ON DELETE RESTRICT,
  ADD COLUMN source_native_event_id text,
  ADD COLUMN occurred_at timestamptz,
  ADD COLUMN reply_to_canonical_message_id bigint;

CREATE TABLE platform_events (
  platform_event_id bigserial PRIMARY KEY,
  endpoint_id bigint NOT NULL REFERENCES conversation_endpoints(endpoint_id) ON DELETE CASCADE,
  native_event_id text NOT NULL CHECK (native_event_id <> ''),
  sender_identity_id bigint REFERENCES principal_identities(principal_identity_id) ON DELETE RESTRICT,
  event_kind text NOT NULL DEFAULT 'message'
    CHECK (event_kind IN ('message', 'edit', 'reaction', 'redaction', 'membership')),
  occurred_at timestamptz NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  source_cursor jsonb,
  raw_payload jsonb,
  raw_payload_truncated boolean NOT NULL DEFAULT false,
  canonical_message_id bigint,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (endpoint_id, native_event_id)
);

CREATE TABLE message_relations (
  relation_id bigserial PRIMARY KEY,
  canonical_message_id bigint NOT NULL,
  relation_kind text NOT NULL CHECK (relation_kind IN ('reply', 'replace', 'reaction')),
  target_canonical_message_id bigint,
  target_native_event_id text,
  reaction_key text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (target_canonical_message_id IS NOT NULL OR target_native_event_id IS NOT NULL),
  UNIQUE NULLS NOT DISTINCT
    (canonical_message_id, relation_kind, target_canonical_message_id, target_native_event_id, reaction_key)
);

CREATE TABLE message_deliveries (
  delivery_id bigserial PRIMARY KEY,
  canonical_message_id bigint NOT NULL,
  endpoint_id bigint NOT NULL REFERENCES conversation_endpoints(endpoint_id) ON DELETE CASCADE,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sending', 'accepted_unconfirmed', 'confirmed', 'failed', 'outcome_unknown', 'suppressed')),
  native_event_id text,
  idempotency_key text NOT NULL,
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at timestamptz NOT NULL DEFAULT now(),
  lease_owner text,
  lease_expires_at timestamptz,
  last_error text,
  last_attempt_at timestamptz,
  confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (canonical_message_id, endpoint_id),
  UNIQUE (endpoint_id, idempotency_key)
);

CREATE INDEX message_deliveries_claim_idx
  ON message_deliveries (next_attempt_at, delivery_id)
  WHERE status IN ('pending', 'failed', 'outcome_unknown');

CREATE TABLE platform_ingest_cursors (
  platform_account_id bigint NOT NULL REFERENCES platform_accounts(platform_account_id) ON DELETE CASCADE,
  stream_key text NOT NULL,
  cursor jsonb NOT NULL,
  source_fingerprint text,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (platform_account_id, stream_key)
);

CREATE TABLE message_dispatches (
  canonical_message_id bigint PRIMARY KEY,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'claimed', 'completed', 'ignored', 'failed')),
  lease_owner text,
  lease_expires_at timestamptz,
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Backfill one explicit account, conversation, endpoint and principal identity
-- for every legacy row.  Existing foreign synthetic ids recover their native
-- values from platform_ids where possible; QQ retains its decimal native id.
INSERT INTO platform_accounts (platform, native_account_id)
SELECT DISTINCT
  COALESCE(pid.platform, 'qq'),
  COALESCE(pid.native_id, m.self_id::text)
FROM messages m
LEFT JOIN platform_ids pid
  ON pid.kind = 'user' AND pid.mapped_id = m.self_id
ON CONFLICT DO NOTHING;

INSERT INTO conversations (conversation_kind, legacy_group_id)
SELECT DISTINCT
  CASE WHEN m.group_id < 0 AND abs(m.group_id) < 1000000000000 THEN 'direct' ELSE 'group' END,
  m.group_id
FROM messages m
ON CONFLICT (legacy_group_id) DO NOTHING;

INSERT INTO conversation_endpoints
  (conversation_id, platform_account_id, native_conversation_id, endpoint_kind)
SELECT DISTINCT
  c.conversation_id,
  a.platform_account_id,
  COALESCE(channel_pid.native_id, m.group_id::text),
  c.conversation_kind
FROM messages m
JOIN conversations c ON c.legacy_group_id = m.group_id
LEFT JOIN platform_ids account_pid
  ON account_pid.kind = 'user' AND account_pid.mapped_id = m.self_id
JOIN platform_accounts a
  ON a.platform = COALESCE(account_pid.platform, 'qq')
 AND a.native_account_id = COALESCE(account_pid.native_id, m.self_id::text)
LEFT JOIN platform_ids channel_pid
  ON channel_pid.kind = 'channel' AND channel_pid.mapped_id = m.group_id
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE legacy_identity_backfill ON COMMIT DROP AS
SELECT identity_rows.*, nextval('principals_principal_id_seq')::bigint AS principal_id
FROM (
  SELECT DISTINCT
    COALESCE(account_pid.platform, 'qq') AS platform,
    COALESCE(account_pid.native_id, m.self_id::text) AS account_native_id,
    COALESCE(user_pid.native_id, m.user_id::text) AS native_user_id,
    COALESCE(m.sender_card, m.sender_nickname, m.user_id::text) AS display_name
  FROM messages m
  LEFT JOIN platform_ids account_pid
    ON account_pid.kind = 'user' AND account_pid.mapped_id = m.self_id
  LEFT JOIN platform_ids user_pid
    ON user_pid.kind = 'user' AND user_pid.mapped_id = m.user_id
) identity_rows;

INSERT INTO principals (principal_id, display_name)
SELECT principal_id, display_name FROM legacy_identity_backfill;

INSERT INTO principal_identities
  (principal_id, platform_account_id, native_user_id, display_name)
SELECT i.principal_id, a.platform_account_id, i.native_user_id, i.display_name
FROM legacy_identity_backfill i
JOIN platform_accounts a
  ON a.platform = i.platform AND a.native_account_id = i.account_native_id
ON CONFLICT DO NOTHING;

WITH resolved AS (
  SELECT
    m.message_id,
    c.conversation_id,
    e.endpoint_id,
    pi.principal_id,
    COALESCE(message_pid.native_id, m.message_id::text) AS native_event_id
  FROM messages m
  JOIN conversations c ON c.legacy_group_id = m.group_id
  LEFT JOIN platform_ids account_pid
    ON account_pid.kind = 'user' AND account_pid.mapped_id = m.self_id
  JOIN platform_accounts a
    ON a.platform = COALESCE(account_pid.platform, 'qq')
   AND a.native_account_id = COALESCE(account_pid.native_id, m.self_id::text)
  LEFT JOIN platform_ids channel_pid
    ON channel_pid.kind = 'channel' AND channel_pid.mapped_id = m.group_id
  JOIN conversation_endpoints e
    ON e.platform_account_id = a.platform_account_id
   AND e.native_conversation_id = COALESCE(channel_pid.native_id, m.group_id::text)
  LEFT JOIN platform_ids user_pid
    ON user_pid.kind = 'user' AND user_pid.mapped_id = m.user_id
  JOIN principal_identities pi
    ON pi.platform_account_id = a.platform_account_id
   AND pi.native_user_id = COALESCE(user_pid.native_id, m.user_id::text)
  LEFT JOIN platform_ids message_pid
    ON message_pid.kind = 'message' AND message_pid.mapped_id = m.message_id
)
UPDATE messages m
SET canonical_message_id = m.ingest_seq,
    canonical_content = jsonb_build_array(jsonb_build_object('type', 'text', 'text', m.rendered_text)),
    conversation_id = r.conversation_id,
    conversation_seq = m.ingest_seq,
    author_principal_id = r.principal_id,
    origin_endpoint_id = r.endpoint_id,
    source_native_event_id = r.native_event_id,
    occurred_at = m.received_at
FROM resolved r
WHERE r.message_id = m.message_id;

SELECT setval(
  'canonical_message_id_seq',
  COALESCE((SELECT max(canonical_message_id) + 1 FROM messages), 1),
  false
);

ALTER TABLE messages
  ALTER COLUMN canonical_message_id SET DEFAULT nextval('canonical_message_id_seq'),
  ALTER COLUMN canonical_message_id SET NOT NULL,
  ALTER COLUMN conversation_id SET NOT NULL,
  ALTER COLUMN conversation_seq SET NOT NULL,
  ALTER COLUMN author_principal_id SET NOT NULL,
  ALTER COLUMN origin_endpoint_id SET NOT NULL,
  ALTER COLUMN source_native_event_id SET NOT NULL,
  ALTER COLUMN occurred_at SET NOT NULL;

ALTER SEQUENCE canonical_message_id_seq OWNED BY messages.canonical_message_id;

ALTER TABLE messages
  ADD CONSTRAINT messages_canonical_message_id_key UNIQUE (canonical_message_id),
  ADD CONSTRAINT messages_conversation_seq_key UNIQUE (conversation_id, conversation_seq),
  ADD CONSTRAINT messages_reply_to_canonical_fk
    FOREIGN KEY (reply_to_canonical_message_id)
    REFERENCES messages(canonical_message_id) ON DELETE SET NULL;

UPDATE messages child
SET reply_to_canonical_message_id = parent.canonical_message_id
FROM messages parent
WHERE child.reply_to_message_id = parent.message_id;

ALTER TABLE platform_events
  ADD CONSTRAINT platform_events_canonical_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;

ALTER TABLE message_relations
  ADD CONSTRAINT message_relations_message_fk
    FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE,
  ADD CONSTRAINT message_relations_target_fk
    FOREIGN KEY (target_canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE SET NULL;

ALTER TABLE message_deliveries
  ADD CONSTRAINT message_deliveries_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;

ALTER TABLE message_dispatches
  ADD CONSTRAINT message_dispatches_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;

INSERT INTO platform_events
  (endpoint_id, native_event_id, sender_identity_id, occurred_at, received_at, canonical_message_id)
SELECT
  m.origin_endpoint_id,
  m.source_native_event_id,
  pi.principal_identity_id,
  m.occurred_at,
  m.received_at,
  m.canonical_message_id
FROM messages m
JOIN conversation_endpoints e ON e.endpoint_id = m.origin_endpoint_id
JOIN principal_identities pi
  ON pi.platform_account_id = e.platform_account_id
 AND pi.principal_id = m.author_principal_id
ON CONFLICT (endpoint_id, native_event_id) DO UPDATE
SET canonical_message_id = EXCLUDED.canonical_message_id;

INSERT INTO message_deliveries
  (canonical_message_id, endpoint_id, status, native_event_id, idempotency_key, confirmed_at)
SELECT
  canonical_message_id,
  origin_endpoint_id,
  'confirmed',
  source_native_event_id,
  'source:' || source_native_event_id,
  received_at
FROM messages
ON CONFLICT (canonical_message_id, endpoint_id) DO NOTHING;

INSERT INTO message_dispatches (canonical_message_id, status)
SELECT canonical_message_id, 'completed' FROM messages
ON CONFLICT DO NOTHING;

-- Compatibility bridge for all existing insertGroupMessage/insertOutbound
-- call sites.  It creates exact canonical identities before the legacy row is
-- accepted, then appends the corresponding source event and confirmed source
-- delivery after the row exists.  The shared ingest kernel can reserve the
-- same platform_event first; the AFTER trigger completes that reservation.
CREATE FUNCTION messages_canonicalize_legacy() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_platform text;
  v_account_native text;
  v_channel_native text;
  v_user_native text;
  v_event_native text;
  v_account_id bigint;
  v_conversation_id bigint;
  v_endpoint_id bigint;
  v_principal_id bigint;
BEGIN
  IF NEW.conversation_id IS NOT NULL THEN
    NEW.conversation_seq := COALESCE(NEW.conversation_seq, NEW.ingest_seq);
    NEW.occurred_at := COALESCE(NEW.occurred_at, NEW.received_at);
    RETURN NEW;
  END IF;

  SELECT platform, native_id INTO v_platform, v_account_native
  FROM platform_ids WHERE kind = 'user' AND mapped_id = NEW.self_id LIMIT 1;
  v_platform := COALESCE(v_platform, 'qq');
  v_account_native := COALESCE(v_account_native, NEW.self_id::text);

  SELECT native_id INTO v_channel_native FROM platform_ids
  WHERE platform = v_platform AND kind = 'channel' AND mapped_id = NEW.group_id LIMIT 1;
  v_channel_native := COALESCE(v_channel_native, NEW.group_id::text);

  SELECT native_id INTO v_user_native FROM platform_ids
  WHERE platform = v_platform AND kind = 'user' AND mapped_id = NEW.user_id LIMIT 1;
  v_user_native := COALESCE(v_user_native, NEW.user_id::text);

  SELECT native_id INTO v_event_native FROM platform_ids
  WHERE platform = v_platform AND kind = 'message' AND mapped_id = NEW.message_id LIMIT 1;
  v_event_native := COALESCE(v_event_native, NEW.message_id::text);

  INSERT INTO platform_accounts (platform, native_account_id)
  VALUES (v_platform, v_account_native)
  ON CONFLICT (platform, native_account_id) DO UPDATE SET updated_at = now()
  RETURNING platform_account_id INTO v_account_id;

  INSERT INTO conversations (conversation_kind, legacy_group_id)
  VALUES (
    CASE WHEN NEW.group_id < 0 AND abs(NEW.group_id) < 1000000000000 THEN 'direct' ELSE 'group' END,
    NEW.group_id)
  ON CONFLICT (legacy_group_id) DO UPDATE SET legacy_group_id = EXCLUDED.legacy_group_id
  RETURNING conversation_id INTO v_conversation_id;

  INSERT INTO conversation_endpoints
    (conversation_id, platform_account_id, native_conversation_id, endpoint_kind)
  VALUES (
    v_conversation_id, v_account_id, v_channel_native,
    CASE WHEN NEW.group_id < 0 AND abs(NEW.group_id) < 1000000000000 THEN 'direct' ELSE 'group' END)
  ON CONFLICT (platform_account_id, native_conversation_id)
  DO UPDATE SET updated_at = now()
  RETURNING endpoint_id INTO v_endpoint_id;

  SELECT principal_id INTO v_principal_id FROM principal_identities
  WHERE platform_account_id = v_account_id AND native_user_id = v_user_native;
  IF v_principal_id IS NULL THEN
    INSERT INTO principals (display_name)
    VALUES (COALESCE(NEW.sender_card, NEW.sender_nickname, v_user_native))
    RETURNING principal_id INTO v_principal_id;
    INSERT INTO principal_identities
      (principal_id, platform_account_id, native_user_id, display_name)
    VALUES (
      v_principal_id, v_account_id, v_user_native,
      COALESCE(NEW.sender_card, NEW.sender_nickname, v_user_native));
  END IF;

  NEW.conversation_id := v_conversation_id;
  NEW.conversation_seq := NEW.ingest_seq;
  NEW.author_principal_id := v_principal_id;
  NEW.origin_endpoint_id := v_endpoint_id;
  NEW.source_native_event_id := v_event_native;
  NEW.occurred_at := NEW.received_at;
  RETURN NEW;
END;
$$;

CREATE TRIGGER messages_canonicalize_legacy_before
BEFORE INSERT ON messages
FOR EACH ROW EXECUTE FUNCTION messages_canonicalize_legacy();

CREATE FUNCTION messages_publish_legacy_source() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_identity_id bigint;
BEGIN
  SELECT pi.principal_identity_id INTO v_identity_id
  FROM conversation_endpoints e
  JOIN principal_identities pi
    ON pi.platform_account_id = e.platform_account_id
   AND pi.principal_id = NEW.author_principal_id
  WHERE e.endpoint_id = NEW.origin_endpoint_id;

  INSERT INTO platform_events
    (endpoint_id, native_event_id, sender_identity_id, occurred_at, received_at, canonical_message_id)
  VALUES (
    NEW.origin_endpoint_id, NEW.source_native_event_id, v_identity_id,
    NEW.occurred_at, NEW.received_at, NEW.canonical_message_id)
  ON CONFLICT (endpoint_id, native_event_id) DO UPDATE
  SET canonical_message_id = COALESCE(platform_events.canonical_message_id, EXCLUDED.canonical_message_id);

  INSERT INTO message_deliveries
    (canonical_message_id, endpoint_id, status, native_event_id, idempotency_key, confirmed_at)
  VALUES (
    NEW.canonical_message_id, NEW.origin_endpoint_id, 'confirmed', NEW.source_native_event_id,
    'source:' || NEW.source_native_event_id, NEW.received_at)
  ON CONFLICT (canonical_message_id, endpoint_id) DO NOTHING;

  INSERT INTO message_dispatches (canonical_message_id, status)
  VALUES (NEW.canonical_message_id, 'completed')
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER messages_publish_legacy_source_after
AFTER INSERT ON messages
FOR EACH ROW EXECUTE FUNCTION messages_publish_legacy_source();

CREATE INDEX messages_canonical_conversation_idx
  ON messages (conversation_id, conversation_seq);
CREATE INDEX platform_events_canonical_idx
  ON platform_events (canonical_message_id);
