-- !uncompact withdraws the newest summaries so their messages return to the
-- raw tail. A withdrawn compartment keeps its handle and evidence; like a
-- superseded one it no longer feeds the prompt, recall or the active-range
-- exclusion, so a later capture can cover the same messages again.
ALTER TABLE conversation_compartments
  DROP CONSTRAINT conversation_compartments_state_check,
  ADD CONSTRAINT conversation_compartments_state_check
    CHECK (state = ANY (ARRAY['staged'::text, 'active'::text, 'superseded'::text, 'withdrawn'::text]));
