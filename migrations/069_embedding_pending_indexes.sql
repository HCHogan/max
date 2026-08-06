-- The embedder asked "is there anything to embed?" with one predicate:
--
--     (embedding IS NULL OR embedding_model IS DISTINCT FROM ?)
--       AND NOT is_synthetic AND char_length(rendered_text) >= 4 AND <not a forward child>
--
-- The OR defeats every index, so answering "no" cost a parallel sequential
-- scan of the whole table: 23,340 buffers, ~182 MB, 31 ms, and it ran 14,754
-- times in eleven days. pg_stat_user_tables agreed — messages had 254,013
-- sequential scans and 2,554,673,408 rows read, almost all of it this.
--
-- The disjunction was also redundant. messages_embedding_metadata_consistent
-- already guarantees that a row with no embedding has no embedding_model
-- either, so "embedding IS NULL" implies "embedding_model IS DISTINCT FROM
-- <any non-null model>". One branch of the OR was contained in the other; it
-- bought nothing and cost the index.
--
-- Split apart, the two branches want two different indexes.

-- The steady-state question. messages_unembedded_idx already covered
-- "embedding IS NULL", but the eligibility conditions were not in it, so all
-- 14,401 unembedded rows had to be heap-fetched every tick to discover that
-- none of them qualified — 19,177 buffers to return zero rows. Folding the
-- conditions into the predicate makes the index hold only rows that actually
-- need work, which in steady state is none of them.
CREATE INDEX messages_embedding_pending_idx
  ON messages (received_at DESC)
  WHERE embedding IS NULL AND NOT is_synthetic AND char_length(rendered_text) >= 4;

-- The model-change question, which is a deploy-time backfill rather than a
-- steady-state concern. A btree over the model lets min()/max() answer "is
-- anything embedded with a model other than the configured one" in two index
-- endpoint lookups, so the expensive fetch only runs when the answer is yes.
CREATE INDEX messages_embedding_model_idx
  ON messages (embedding_model)
  WHERE embedding IS NOT NULL;
