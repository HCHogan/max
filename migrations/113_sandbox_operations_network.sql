-- Existing sandboxes adopt the broker-selected operations network at startup.
ALTER TABLE sandboxes DROP CONSTRAINT sandboxes_network_mode_check;
ALTER TABLE sandboxes ADD CONSTRAINT sandboxes_network_mode_check
  CHECK (network_mode IN ('bridge', 'none', 'max-sandbox', 'maxops'));
