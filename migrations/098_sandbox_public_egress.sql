-- Keep historical modes readable; runtime reconciliation moves existing
-- workspaces to the operator-provisioned public-egress network without
-- replacing their durable work volumes.
ALTER TABLE sandboxes DROP CONSTRAINT sandboxes_network_mode_check;
ALTER TABLE sandboxes ADD CONSTRAINT sandboxes_network_mode_check
  CHECK (network_mode IN ('bridge', 'none', 'max-sandbox'));
