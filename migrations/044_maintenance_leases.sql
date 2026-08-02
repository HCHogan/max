-- Durable, independently fenced ownership for projection maintenance.
--
-- A domain is deliberately a code-owned name.  Jobs which may mutate the
-- same projection share a domain; unrelated jobs use different domains and
-- therefore never block or accidentally release one another.

CREATE TABLE maintenance_leases (
    domain            text        PRIMARY KEY CHECK (domain <> ''),
    owner             text        NOT NULL CHECK (owner <> ''),
    fencing_token     bigint      NOT NULL CHECK (fencing_token > 0),
    acquired_at       timestamptz NOT NULL DEFAULT now(),
    heartbeat_at      timestamptz NOT NULL DEFAULT now(),
    expires_at        timestamptz NOT NULL,
    CHECK (expires_at > heartbeat_at)
);

CREATE INDEX maintenance_leases_expiry_idx
    ON maintenance_leases (expires_at);
