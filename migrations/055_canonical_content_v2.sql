-- Canonical content v2 (ADR 003 slice 2): one closed, versioned IR body
-- per message, encoded as {"v":2,"nodes":[...]}.
--
-- QQ inbound rows rebuild from their raw segments — the richer source the
-- v1 projection destroyed (faces, cards, files, videos, stickers).  All
-- other v1 arrays lift part by part.  Mentions resolve to principal
-- identities through the message's origin endpoint; a mention whose
-- identity cannot be found degrades to readable @display text instead of
-- inventing principals inside a migration.  rendered_text is not
-- rewritten: the prompt-projection vocabulary is unchanged by design.
--
-- Node objects written here may carry explicit JSON nulls for optional
-- fields; the Haskell decoder treats null and absent identically.

-- Redactions get their own relation kind: an edit supersedes content, a
-- redaction removes it.  Overloading 'replace' for both was a defect.
ALTER TABLE message_relations
  DROP CONSTRAINT message_relations_relation_kind_check;
ALTER TABLE message_relations
  ADD CONSTRAINT message_relations_relation_kind_check
  CHECK (relation_kind IN ('reply', 'replace', 'redacts', 'reaction'));

-- Part A: QQ inbound rows, rebuilt from segments.
WITH qq_rows AS (
  SELECT m.canonical_message_id, m.segments, m.canonical_content, m.origin_endpoint_id
    FROM messages m
   WHERE m.source_platform = 'qq'
     AND m.message_origin = 'inbound'
     AND jsonb_typeof(m.canonical_content) = 'array'
     AND jsonb_typeof(m.segments) = 'array'
), qq_segments AS (
  -- The v1 QQ normalizer emitted exactly one content part for every segment
  -- except replies and empty text. Pair by that production invariant so the
  -- text projection can recover names that Segment.ToJSON did not retain
  -- (notably QQ face names and the readable card summary).
  SELECT r.canonical_message_id, r.origin_endpoint_id, s.segment, s.seg_ord,
         row_number() OVER (PARTITION BY r.canonical_message_id ORDER BY s.seg_ord) AS part_ord
    FROM qq_rows r
   CROSS JOIN LATERAL jsonb_array_elements(r.segments) WITH ORDINALITY AS s(segment, seg_ord)
   WHERE s.segment->>'type' <> 'reply'
     AND NOT (s.segment->>'type' = 'text'
              AND coalesce(s.segment->'data'->>'text', '') = '')
), qq_parts AS (
  SELECT r.canonical_message_id, p.part, p.part_ord
    FROM qq_rows r
   CROSS JOIN LATERAL jsonb_array_elements(r.canonical_content) WITH ORDINALITY AS p(part, part_ord)
), qq_nodes AS (
  SELECT r.canonical_message_id,
         jsonb_agg(n.node ORDER BY s.seg_ord) FILTER (WHERE n.node IS NOT NULL) AS nodes
    FROM qq_rows r
   JOIN qq_segments s USING (canonical_message_id)
   LEFT JOIN qq_parts p
     ON p.canonical_message_id = s.canonical_message_id
    AND p.part_ord = s.part_ord
   CROSS JOIN LATERAL (
     SELECT CASE s.segment->>'type'
       WHEN 'text' THEN
         CASE WHEN coalesce(s.segment->'data'->>'text', '') = '' THEN NULL
              ELSE jsonb_build_object('type', 'text', 'text', s.segment->'data'->>'text')
         END
       WHEN 'at' THEN (
         SELECT coalesce((SELECT CASE
             WHEN pi.principal_identity_id IS NULL THEN
               jsonb_build_object('type', 'text', 'text', '@' || (s.segment->'data'->>'qq'))
             ELSE
               jsonb_build_object(
                 'type', 'mention',
                 'identity', pi.principal_identity_id,
                 'display', coalesce(nullif(btrim(coalesce(pi.display_name, '')), ''),
                                     s.segment->'data'->>'qq'))
           END
           FROM conversation_endpoints e
           LEFT JOIN principal_identities pi
            ON pi.platform_account_id = e.platform_account_id
            AND pi.native_user_id = s.segment->'data'->>'qq'
          WHERE e.endpoint_id = r.origin_endpoint_id),
          jsonb_build_object('type', 'text', 'text', '@' || coalesce(s.segment->'data'->>'qq', ''))))
       WHEN 'reply' THEN NULL
       WHEN 'image' THEN
         jsonb_build_object(
           'type', 'media',
           'kind', CASE WHEN coalesce(s.segment->'data'->>'sub_type', '0') = '1'
                        THEN 'sticker' ELSE 'image' END,
           'source', CASE
             WHEN coalesce(nullif(s.segment->'data'->>'url', ''),
                           nullif(s.segment->'data'->>'file', '')) ~* '^https?://'
               OR coalesce(nullif(s.segment->'data'->>'url', ''),
                           nullif(s.segment->'data'->>'file', '')) LIKE 'mxc://%'
               OR coalesce(nullif(s.segment->'data'->>'url', ''),
                           nullif(s.segment->'data'->>'file', '')) ~ '^blob:[0-9a-f]{64}$'
             THEN coalesce(nullif(s.segment->'data'->>'url', ''),
                           nullif(s.segment->'data'->>'file', ''))
             WHEN coalesce(nullif(s.segment->'data'->>'url', ''),
                           nullif(s.segment->'data'->>'file', '')) LIKE '//%'
             THEN 'https:' || coalesce(nullif(s.segment->'data'->>'url', ''),
                                       nullif(s.segment->'data'->>'file', ''))
             ELSE NULL END,
           'description', nullif(btrim(coalesce(s.segment->'data'->>'summary', '')), ''),
           'raw', s.segment)
       WHEN 'face' THEN
         jsonb_build_object(
           'type', 'emote',
           'platform', 'qq',
           'native_id', coalesce(s.segment->'data'->>'id', ''),
           'name', coalesce(
             nullif(btrim(ltrim(coalesce(s.segment->'data'->'raw'->>'faceText', ''), '/')), ''),
             CASE WHEN p.part->>'type' = 'text'
                        AND coalesce(p.part->>'text', '') <> '[face#' || coalesce(s.segment->'data'->>'id', '') || ']'
                  THEN nullif(btrim(p.part->>'text'), '') END),
           'raw', s.segment)
       WHEN 'file' THEN
         jsonb_build_object(
           'type', 'media',
           'kind', 'file',
           'source', CASE WHEN s.segment->'data'->>'url' ~* '^https?://'
                                OR s.segment->'data'->>'url' LIKE 'mxc://%'
                                OR s.segment->'data'->>'url' ~ '^blob:[0-9a-f]{64}$'
                          THEN s.segment->'data'->>'url' END,
           'name', nullif(s.segment->'data'->>'file', ''),
           'size', CASE WHEN coalesce(s.segment->'data'->>'file_size', '') ~ '^[0-9]+$'
                        THEN (s.segment->'data'->>'file_size')::bigint END,
           'raw', s.segment)
       WHEN 'video' THEN
         jsonb_build_object(
           'type', 'media',
           'kind', 'video',
           'source', CASE WHEN s.segment->'data'->>'url' ~* '^https?://'
                                OR s.segment->'data'->>'url' LIKE 'mxc://%'
                                OR s.segment->'data'->>'url' ~ '^blob:[0-9a-f]{64}$'
                          THEN s.segment->'data'->>'url' END,
           'size', CASE WHEN coalesce(s.segment->'data'->>'file_size', '') ~ '^[0-9]+$'
                        THEN (s.segment->'data'->>'file_size')::bigint END,
           'raw', s.segment)
       WHEN 'json' THEN
         jsonb_build_object(
           'type', 'card',
           'title', CASE WHEN p.part->>'type' = 'text' THEN nullif(p.part->>'text', '') END,
           'raw', s.segment)
       WHEN 'forward' THEN
         CASE WHEN coalesce(s.segment->'data'->>'id', '') = '' THEN
             jsonb_build_object(
               'type', 'unsupported',
               'source', 'qq:forward',
               'description', 'forward',
               'raw', s.segment->'data')
           ELSE
             jsonb_build_object('type', 'forward', 'native_id', s.segment->'data'->>'id')
         END
       ELSE
         jsonb_build_object(
           'type', 'unsupported',
           'source', 'qq:' || coalesce(s.segment->>'type', 'unknown'),
           'description', coalesce(s.segment->>'type', 'unknown'),
           'raw', s.segment->'data')
     END AS node
   ) n
   GROUP BY r.canonical_message_id
)
UPDATE messages m
   SET canonical_content = jsonb_build_object('v', 2, 'nodes', coalesce(q.nodes, '[]'::jsonb))
  FROM qq_nodes q
 WHERE m.canonical_message_id = q.canonical_message_id;

-- Part B: every remaining v1 array lifts part by part (Matrix, iMessage,
-- bot outbound, and QQ rows whose segments were unusable).
WITH v1_rows AS (
  SELECT m.canonical_message_id, m.canonical_content, m.origin_endpoint_id
    FROM messages m
   WHERE jsonb_typeof(m.canonical_content) = 'array'
), lifted AS (
  SELECT r.canonical_message_id,
         jsonb_agg(n.node ORDER BY p.part_ord) FILTER (WHERE n.node IS NOT NULL) AS nodes
    FROM v1_rows r
   CROSS JOIN LATERAL jsonb_array_elements(r.canonical_content) WITH ORDINALITY AS p(part, part_ord)
   CROSS JOIN LATERAL (
     SELECT CASE p.part->>'type'
       WHEN 'text' THEN
         CASE WHEN coalesce(p.part->>'text', '') = '' THEN NULL
              ELSE jsonb_build_object('type', 'text', 'text', p.part->>'text')
         END
       WHEN 'mention' THEN (
         SELECT coalesce((SELECT CASE
             WHEN pi.principal_identity_id IS NULL THEN
               jsonb_build_object(
                 'type', 'text',
                 'text', '@' || coalesce(nullif(p.part->>'display', ''), p.part->>'native_user_id'))
             ELSE
               jsonb_build_object(
                 'type', 'mention',
                 'identity', pi.principal_identity_id,
                 'display', coalesce(nullif(p.part->>'display', ''),
                                     nullif(btrim(coalesce(pi.display_name, '')), ''),
                                     p.part->>'native_user_id'))
           END
           FROM conversation_endpoints e
           LEFT JOIN principal_identities pi
            ON pi.platform_account_id = e.platform_account_id
            AND pi.native_user_id = p.part->>'native_user_id'
          WHERE e.endpoint_id = r.origin_endpoint_id),
          jsonb_build_object(
            'type', 'text',
            'text', '@' || coalesce(nullif(p.part->>'display', ''), p.part->>'native_user_id', ''))))
       WHEN 'media' THEN
         jsonb_build_object(
           'type', 'media',
           'kind', CASE
               WHEN btrim(coalesce(p.part->>'caption', '')) = '[sticker]' THEN 'sticker'
               WHEN p.part->'source'->>'mime_type' LIKE 'video/%' THEN 'video'
               WHEN p.part->'source'->>'mime_type' LIKE 'audio/%' THEN 'audio'
               WHEN p.part->'source'->>'mime_type' LIKE 'image/%' THEN 'image'
               WHEN p.part->'source'->>'mime_type' IS NULL THEN 'image'
               ELSE 'file' END,
           'source', CASE WHEN p.part->'source'->>'url' ~* '^https?://'
                                OR p.part->'source'->>'url' LIKE 'mxc://%'
                                OR p.part->'source'->>'url' ~ '^blob:[0-9a-f]{64}$'
                          THEN p.part->'source'->>'url'
                          WHEN p.part->'source'->>'url' LIKE '//%'
                          THEN 'https:' || (p.part->'source'->>'url') END,
           'mime', p.part->'source'->>'mime_type',
           'size', CASE WHEN coalesce(p.part->'source'->>'size', '') ~ '^[0-9]+$'
                        THEN (p.part->'source'->>'size')::bigint END,
           'description', CASE WHEN btrim(coalesce(p.part->>'caption', ''))
                                    IN ('', '[image]', '[sticker]', '[media]') THEN NULL
                               ELSE p.part->>'caption' END)
       WHEN 'unsupported' THEN
         jsonb_build_object(
           'type', 'unsupported',
           'source', coalesce(p.part->>'description', 'unknown'),
           'description', coalesce(nullif(split_part(coalesce(p.part->>'description', ''), ':', 2), ''),
                                   p.part->>'description',
                                   'unknown'))
       ELSE
         jsonb_build_object(
           'type', 'unsupported',
           'source', 'v1:' || coalesce(p.part->>'type', 'unknown'),
           'description', coalesce(p.part->>'type', 'unknown'))
     END AS node
   ) n
   GROUP BY r.canonical_message_id
)
UPDATE messages m
   SET canonical_content = jsonb_build_object('v', 2, 'nodes', coalesce(l.nodes, '[]'::jsonb))
  FROM lifted l
 WHERE m.canonical_message_id = l.canonical_message_id;

-- Sweep: rows whose v1 array produced no rows above (empty arrays) still
-- become explicit empty v2 bodies, so no reader ever sees a bare array.
UPDATE messages
   SET canonical_content = jsonb_build_object('v', 2, 'nodes', '[]'::jsonb)
 WHERE jsonb_typeof(canonical_content) = 'array';
