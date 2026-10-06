-- Destiny 2 through the Bungie.net API: opt-in skills per conversation,
-- one-time browser login states, per-person account links, and a projected
-- local copy of the localized manifest.

-- Opt-in builtin skills (currently destiny) are visible only in the
-- conversations listed here. Group admins toggle rows with !destiny on/off.
CREATE TABLE skill_enables (
  group_id bigint NOT NULL,
  name text NOT NULL CHECK (name <> ''),
  enabled_by bigint REFERENCES principals(principal_id) ON DELETE SET NULL,
  enabled_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (group_id, name)
);

-- One pending browser login. Only the SHA-256 of the OAuth state parameter is
-- stored; a state is consumed by its first callback, successful or not.
CREATE TABLE bungie_oauth_states (
  state_sha256 text PRIMARY KEY,
  principal_id bigint NOT NULL REFERENCES principals(principal_id) ON DELETE CASCADE,
  requester_name text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL
);

CREATE INDEX bungie_oauth_states_expiry_idx ON bungie_oauth_states (expires_at);

-- A person's linked Bungie.net account. Tokens are sealed with the process
-- state key, so a database copy alone cannot act on the account.
CREATE TABLE bungie_links (
  principal_id bigint PRIMARY KEY REFERENCES principals(principal_id) ON DELETE CASCADE,
  bungie_membership_id bigint NOT NULL,
  bungie_name text NOT NULL,
  destiny_membership_type integer,
  destiny_membership_id bigint,
  sealed_tokens text NOT NULL,
  access_expires_at timestamptz NOT NULL,
  refresh_expires_at timestamptz NOT NULL,
  linked_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Projected manifest definitions (zh-chs, plus the English name for search).
-- Each kind is replaced in one transaction when Bungie publishes a new
-- version; destiny_manifest_kinds records which version each kind holds.
CREATE TABLE destiny_definitions (
  kind text NOT NULL,
  hash bigint NOT NULL CHECK (hash >= 0 AND hash <= 4294967295),
  name text NOT NULL DEFAULT '',
  name_en text NOT NULL DEFAULT '',
  data jsonb NOT NULL,
  PRIMARY KEY (kind, hash)
);

CREATE TABLE destiny_manifest_kinds (
  kind text PRIMARY KEY,
  version text NOT NULL,
  row_count integer NOT NULL CHECK (row_count >= 0),
  synced_at timestamptz NOT NULL DEFAULT now()
);
