-- Prompt traces distinguish the operator-forced raw-ledger release fallback
-- from normal tiered reads.  Historical legacy rows remain readable.

ALTER TABLE context_plan_traces
    DROP CONSTRAINT context_plan_traces_history_mode_check;

ALTER TABLE context_plan_traces
    ADD CONSTRAINT context_plan_traces_history_mode_check CHECK (
        history_mode IN ('legacy', 'tiered', 'raw_emergency')
    );
