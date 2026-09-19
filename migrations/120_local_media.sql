-- Completion is derived history, including an empty forward expansion.
CREATE TABLE forward_expansions (
  canonical_message_id bigint NOT NULL REFERENCES messages(canonical_message_id) ON DELETE CASCADE,
  forward_id text NOT NULL,
  top_level_count integer NOT NULL CHECK(top_level_count >= 0),
  completed_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(canonical_message_id,forward_id)
);
-- The old worker deleted a job only after importing every node. A retained job
-- may have partial children, so those sources remain eligible for a fresh read.
INSERT INTO forward_expansions(canonical_message_id,forward_id,top_level_count)
SELECT parent.canonical_message_id,node->>'native_id',count(DISTINCT child.canonical_message_id)
FROM messages parent
CROSS JOIN LATERAL jsonb_array_elements(parent.canonical_content->'nodes') node
JOIN message_relations relation ON relation.target_canonical_message_id=parent.canonical_message_id AND relation.relation_kind='contained_in'
JOIN messages child ON child.canonical_message_id=relation.canonical_message_id
JOIN platform_events event ON event.canonical_message_id=child.canonical_message_id AND event.raw_payload->>'forward_id'=node->>'native_id'
WHERE node->>'type'='forward'
  AND NOT EXISTS (SELECT 1 FROM fetch_jobs j WHERE j.kind='forward' AND j.dedupe_key=parent.canonical_message_id::text || ':' || (node->>'native_id'))
GROUP BY parent.canonical_message_id,node->>'native_id';
DROP TRIGGER fetch_jobs_notify_all_timelines ON fetch_jobs;
-- Archive diagnostics; startup derives missing work from canonical history.
UPDATE fetch_jobs SET claimed_until=NULL,parked_at=COALESCE(parked_at,now()),
  last_error=COALESCE(last_error,'media execution queue retired; canonical sources retained');
