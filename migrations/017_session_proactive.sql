-- Per-session proactive-trigger override, set by !proactive on/off.
-- NULL = follow the config-level default (on whenever intent.profile is
-- configured).  When effective proactive mode is on, an intent
-- classifier may trigger the bot on messages that neither @-mention nor
-- quote it.
ALTER TABLE sessions
    ADD COLUMN proactive_override boolean;
