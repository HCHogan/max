BEGIN;
INSERT INTO messages(message_id,group_id,user_id,self_id,segments,rendered_text,ingest_seq,
                     canonical_message_id,canonical_content,conversation_id,conversation_seq,
                     author_principal_id,origin_endpoint_id,source_native_event_id,occurred_at,message_origin,source_platform)
SELECT -900003,group_id,user_id,self_id,'[]','partial forward child',
       (SELECT max(ingest_seq)+1 FROM messages),(SELECT max(canonical_message_id)+1 FROM messages),
       '{"v":2,"nodes":[{"type":"text","text":"partial forward child"}]}',conversation_id,
       (SELECT max(conversation_seq)+1 FROM messages),author_principal_id,origin_endpoint_id,
       'media-upgrade-partial',now(),'inbound',source_platform
FROM messages ORDER BY canonical_message_id DESC LIMIT 1;
CREATE TEMP TABLE media_fixture AS
  SELECT canonical_message_id,origin_endpoint_id,source_native_event_id,
         row_number() OVER (ORDER BY canonical_message_id) AS n
  FROM messages ORDER BY canonical_message_id LIMIT 3;
UPDATE messages SET canonical_content='{"v":2,"nodes":[{"type":"forward","native_id":"complete"},{"type":"forward","native_id":"partial"}]}'
WHERE canonical_message_id=(SELECT canonical_message_id FROM media_fixture WHERE n=1);
INSERT INTO message_relations(canonical_message_id,relation_kind,target_canonical_message_id,relation_position)
SELECT child.canonical_message_id,'contained_in',parent.canonical_message_id,child.n::integer
FROM media_fixture child CROSS JOIN media_fixture parent WHERE child.n>1 AND parent.n=1;
INSERT INTO platform_events(endpoint_id,native_event_id,occurred_at,canonical_message_id,raw_payload)
SELECT origin_endpoint_id,'media-upgrade-child:' || n,now(),canonical_message_id,
       jsonb_build_object('forward_id',CASE WHEN n=2 THEN 'complete' ELSE 'partial' END)
FROM media_fixture WHERE n>1;
INSERT INTO fetch_jobs(kind,dedupe_key,payload,attempts,claimed_until,last_error)
SELECT 'forward',canonical_message_id::text || ':partial','{"old_job":"keep diagnostic payload"}',2,now()+interval '1 minute','old error'
FROM media_fixture WHERE n=1;
INSERT INTO images(sha256,mime_type,bytes_size,local_path) VALUES('upgrade-media','image/png',3,'fixture');
INSERT INTO message_images(canonical_message_id,sha256,seg_index)
SELECT canonical_message_id,'upgrade-media',0 FROM media_fixture WHERE n=2;
CREATE TEMP TABLE media_messages_before AS SELECT to_jsonb(m) AS row FROM messages m;
CREATE TEMP TABLE media_links_before AS SELECT to_jsonb(i) AS row FROM message_images i;
CREATE TEMP TABLE media_jobs_before AS SELECT id,payload,attempts,last_error FROM fetch_jobs;
\ir ../../migrations/120_local_media.sql
DO $$ BEGIN
  IF (SELECT count(*) FROM media_fixture)<>3 THEN RAISE EXCEPTION 'media fixture requires three source messages'; END IF;
  IF NOT EXISTS (SELECT 1 FROM forward_expansions WHERE forward_id='complete' AND top_level_count=1)
    THEN RAISE EXCEPTION 'completed forward was not retained'; END IF;
  IF EXISTS (SELECT 1 FROM forward_expansions WHERE forward_id='partial')
    THEN RAISE EXCEPTION 'partial forward was falsely marked complete'; END IF;
  IF EXISTS (SELECT 1 FROM fetch_jobs WHERE claimed_until IS NOT NULL OR parked_at IS NULL)
    THEN RAISE EXCEPTION 'old execution state was not retired'; END IF;
  IF EXISTS (SELECT * FROM media_jobs_before EXCEPT SELECT id,payload,attempts,last_error FROM fetch_jobs)
    THEN RAISE EXCEPTION 'retained media diagnostics changed'; END IF;
  IF EXISTS (SELECT row FROM media_messages_before EXCEPT SELECT to_jsonb(m) FROM messages m)
    THEN RAISE EXCEPTION 'media migration changed history'; END IF;
  IF EXISTS (SELECT row FROM media_links_before EXCEPT SELECT to_jsonb(i) FROM message_images i)
    THEN RAISE EXCEPTION 'media migration changed attachment links'; END IF;
END $$;
COMMIT;
