-- Per-session debug override, set by !debug on/off.  NULL = follow
-- AppConfig.debug (the config-level default).  When effective debug
-- is on, the agent loop posts each tool call to the group as a
-- status line.
ALTER TABLE sessions
    ADD COLUMN debug_override boolean;
