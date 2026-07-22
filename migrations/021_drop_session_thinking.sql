-- The !model think on/off toggle is removed: models now decide
-- thinking on their own and most providers no longer accept an
-- explicit enable/disable field.
ALTER TABLE sessions
    DROP COLUMN thinking_override;
