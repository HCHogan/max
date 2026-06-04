-- !model think on/off sets this; null = follow the profile's
-- thinking setting (or, if the profile didn't set one, the upstream
-- server's default — DeepSeek defaults thinking to enabled).
ALTER TABLE sessions
    ADD COLUMN thinking_override boolean;
