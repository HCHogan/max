-- Session-level btw notes are gone: since !btw grew its current
-- semantics (inject into a running task's inbox, or fire an ephemeral
-- one-shot ask) nothing ever appended to this queue — it was
-- render-only dead weight.
ALTER TABLE sessions DROP COLUMN btw_notes;
