BEGIN;
INSERT INTO episode_capture_runs(conversation_id,expected_cursor_seq,start_ingest_seq,end_ingest_seq,
  source_hash,source_message_count,scheduling_reason,historian_profile,prompt_version,schema_version,status)
SELECT group_id,0,min(ingest_seq),max(ingest_seq),conversation_source_hash(group_id,min(ingest_seq),max(ingest_seq)),
  count(*)::integer,'idle','single-summary-upgrade','historian/test',2,'published'
FROM messages GROUP BY group_id;
INSERT INTO conversation_compartments(conversation_id,capture_run_id,start_ingest_seq,end_ingest_seq,
  source_hash,source_message_count,summary_p1,summary_p2,summary_p3,episode_kind,importance,confidence,
  state,historian_profile,prompt_version,schema_version,materialization_version)
SELECT conversation_id,id,start_ingest_seq,end_ingest_seq,source_hash,source_message_count,
  'full retained '||id,
  CASE WHEN n=1 THEN 'full retained '||id ELSE 'compact-only-key '||id END,
  CASE WHEN n=1 THEN 'full retained '||id ELSE 'anchor-only-key '||id END,
  'mixed',0.5,1,CASE WHEN n=1 THEN 'active' ELSE 'staged' END,'fixture','historian/test',2,1
FROM (SELECT *,row_number() OVER (ORDER BY id) AS n FROM episode_capture_runs WHERE historian_profile='single-summary-upgrade') runs;
UPDATE conversation_compartments SET embedding='[1,0]'::vector,embedding_model='fixture',embedding_dimensions=2,
  embedding_content_hash=encode(digest(convert_to(summary_p1,'UTF8'),'sha256'),'hex'),embedding_updated_at=now();
INSERT INTO compartment_evidence(compartment_id,summary_tier,source_canonical_message_id,source_principal_id)
SELECT compartment.id,tier,message.canonical_message_id,message.author_principal_id
FROM conversation_compartments compartment
JOIN messages message ON message.group_id=compartment.conversation_id
  AND message.ingest_seq BETWEEN compartment.start_ingest_seq AND compartment.end_ingest_seq
CROSS JOIN (VALUES ('p1'),('p2'),('p3')) tiers(tier);
CREATE TEMP TABLE summaries_before AS SELECT * FROM conversation_compartments;
CREATE TEMP TABLE summary_evidence_before AS SELECT * FROM compartment_evidence;
CREATE TEMP TABLE summary_messages_before AS SELECT to_jsonb(m) AS row FROM messages m;
\ir ../../migrations/122_single_summary.sql
DO $$ BEGIN
  IF (SELECT count(*) FROM summaries_before)<2 THEN RAISE EXCEPTION 'fixture requires distinct legacy summaries'; END IF;
  IF EXISTS (SELECT 1 FROM summaries_before old JOIN conversation_compartments current USING(id)
    WHERE position(old.summary_p1 IN current.summary)=0
       OR position(old.summary_p2 IN current.summary)=0
       OR position(old.summary_p3 IN current.summary)=0)
    THEN RAISE EXCEPTION 'legacy summary text was lost'; END IF;
  IF EXISTS (SELECT to_jsonb(old)-ARRAY['embedding','embedding_model','embedding_dimensions','embedding_content_hash','embedding_updated_at'] FROM summaries_before old
    EXCEPT SELECT to_jsonb(current)-ARRAY['summary','embedding','embedding_model','embedding_dimensions','embedding_content_hash','embedding_updated_at'] FROM conversation_compartments current)
    THEN RAISE EXCEPTION 'source range, handle or archived metadata changed'; END IF;
  IF EXISTS (SELECT 1 FROM summaries_before old JOIN conversation_compartments current USING(id)
    WHERE (old.summary_p1=old.summary_p2 AND old.summary_p1=old.summary_p3 AND
           (current.summary<>old.summary_p1 OR current.embedding IS DISTINCT FROM old.embedding))
       OR ((old.summary_p1<>old.summary_p2 OR old.summary_p1<>old.summary_p3) AND current.embedding IS NOT NULL))
    THEN RAISE EXCEPTION 'summary deduplication or vector invalidation failed'; END IF;
  IF (SELECT count(*) FROM summary_evidence_before)=0 THEN RAISE EXCEPTION 'fixture requires legacy citations'; END IF;
  IF EXISTS (SELECT * FROM summary_evidence_before EXCEPT SELECT * FROM compartment_evidence)
    THEN RAISE EXCEPTION 'legacy citations changed'; END IF;
  IF EXISTS (SELECT DISTINCT compartment_id,source_canonical_message_id,source_principal_id FROM summary_evidence_before
    EXCEPT SELECT compartment_id,source_canonical_message_id,source_principal_id FROM compartment_evidence WHERE summary_tier='summary')
    THEN RAISE EXCEPTION 'merged summary lost a citation'; END IF;
  IF EXISTS (SELECT row FROM summary_messages_before EXCEPT SELECT to_jsonb(m) FROM messages m)
    THEN RAISE EXCEPTION 'summary migration changed raw history'; END IF;
END $$;
COMMIT;
