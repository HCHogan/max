-- Model-facing episode references must not expose the internal compartment
-- sequence.  Handles remain stable for the lifetime of one immutable
-- compartment and are re-authorized against the current conversation on
-- every expansion.

ALTER TABLE conversation_compartments
    ADD COLUMN expand_handle uuid NOT NULL DEFAULT gen_random_uuid(),
    ADD CONSTRAINT conversation_compartments_expand_handle_key UNIQUE (expand_handle);

-- The rollout is one feature-wide cutover after offline gates, not a
-- production canary.  Preserve existing development revisions while naming
-- future initial publications accurately.
ALTER TABLE context_materializations
    DROP CONSTRAINT context_materializations_reason_check;

UPDATE context_materializations
SET reason = 'initial_materialization'
WHERE reason = 'initial_canary';

ALTER TABLE context_materializations
    ADD CONSTRAINT context_materializations_reason_check CHECK (
        reason IN ('initial_materialization', 'high_water', 'projection_change', 'manual_rebuild')
    );
