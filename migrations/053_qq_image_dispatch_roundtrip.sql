-- The canonical dispatch cutover persisted QQ image segments through their
-- outbound OneBot encoding (`data.file`) and then decoded only `data.url`.
-- Those rows reached the transcript, but their media jobs were never queued.
-- NapCat also supplies `summary: ""` for ordinary images; treating that as a
-- real caption rendered the canonical message as an empty line.

-- Repair the canonical projection. Media-producing segments and canonical
-- media parts are paired by rank because reply/empty-text segments do not
-- produce content parts and therefore make raw JSON ordinality insufficient.
CREATE TEMP TABLE qq_image_dispatch_roundtrip_targets (
    canonical_message_id bigint PRIMARY KEY
) ON COMMIT DROP;

INSERT INTO qq_image_dispatch_roundtrip_targets (canonical_message_id)
SELECT m.canonical_message_id
  FROM messages m
 WHERE m.source_platform = 'qq'
   AND m.message_origin = 'inbound'
   AND m.kind = 'chat'
   AND EXISTS (
       SELECT 1
         FROM jsonb_array_elements(m.canonical_content) part
        WHERE part->>'type' = 'media'
          AND part->'caption' = to_jsonb(''::text)
   );

WITH targets AS (
    SELECT m.canonical_message_id, m.segments, m.canonical_content
      FROM messages m
      JOIN qq_image_dispatch_roundtrip_targets t
        USING (canonical_message_id)
), content_parts AS (
    SELECT t.canonical_message_id,
           part,
           part_ord,
           count(*) FILTER (WHERE part->>'type' = 'media') OVER (
               PARTITION BY t.canonical_message_id ORDER BY part_ord
           ) AS media_rank
      FROM targets t
      CROSS JOIN LATERAL jsonb_array_elements(t.canonical_content)
          WITH ORDINALITY AS p(part, part_ord)
), media_segments AS (
    SELECT t.canonical_message_id,
           segment,
           row_number() OVER (
               PARTITION BY t.canonical_message_id ORDER BY segment_ord
           ) AS media_rank
      FROM targets t
      CROSS JOIN LATERAL jsonb_array_elements(t.segments)
          WITH ORDINALITY AS s(segment, segment_ord)
     WHERE segment->>'type' IN ('image', 'file', 'video')
), rebuilt AS (
    SELECT p.canonical_message_id,
           jsonb_agg(
               CASE
                   WHEN p.part->>'type' = 'media'
                    AND p.part->'caption' = to_jsonb(''::text)
                    AND s.segment->>'type' = 'image'
                   THEN jsonb_set(
                       p.part,
                       '{caption}',
                       to_jsonb(
                           CASE
                               WHEN COALESCE(s.segment->'data'->>'sub_type', '0') = '1'
                               THEN '[sticker]'
                               ELSE '[image]'
                           END
                       )
                   )
                   ELSE p.part
               END
               ORDER BY p.part_ord
           ) AS canonical_content
      FROM content_parts p
      LEFT JOIN media_segments s
        ON s.canonical_message_id = p.canonical_message_id
       AND s.media_rank = p.media_rank
     GROUP BY p.canonical_message_id
)
UPDATE messages m
   SET canonical_content = r.canonical_content,
       rendered_text = rendered.value
  FROM rebuilt r
  CROSS JOIN LATERAL (
      SELECT string_agg(
                 CASE part->>'type'
                     WHEN 'text' THEN COALESCE(part->>'text', '')
                     WHEN 'mention' THEN '@' || COALESCE(part->>'display', part->>'native_user_id', '')
                     WHEN 'media' THEN COALESCE(NULLIF(btrim(part->>'caption'), ''), '[media]')
                     WHEN 'unsupported' THEN '[unsupported: ' || COALESCE(part->>'description', '') || ']'
                     ELSE ''
                 END,
                 ' ' ORDER BY part_ord
             ) AS value
        FROM jsonb_array_elements(r.canonical_content)
            WITH ORDINALITY AS p(part, part_ord)
  ) rendered
 WHERE m.canonical_message_id = r.canonical_message_id;

-- Recreate every missing per-segment media obligation. Successful historical
-- rows already have message_images and are skipped; a live or parked queue row
-- wins through the natural-key conflict.
INSERT INTO fetch_jobs (kind, dedupe_key, payload)
SELECT 'image',
       m.message_id::text || ':' || (segment_ord - 1)::text,
       jsonb_build_object(
           'message_id', m.message_id,
           'seg_index', segment_ord - 1,
           'url', COALESCE(NULLIF(segment->'data'->>'url', ''), NULLIF(segment->'data'->>'file', '')),
           'group_id', m.group_id,
           'sticker', CASE
               WHEN COALESCE(segment->'data'->>'sub_type', '0') = '1'
               THEN jsonb_build_object(
                   'kind', 'custom',
                   'emoji_id', NULL,
                   'package_id', NULL,
                   'key', NULL,
                   'summary', NULLIF(segment->'data'->>'summary', '')
               )
               ELSE 'null'::jsonb
           END,
           'kind', 'image'
       )
  FROM messages m
  JOIN qq_image_dispatch_roundtrip_targets t
    USING (canonical_message_id)
  CROSS JOIN LATERAL jsonb_array_elements(m.segments)
      WITH ORDINALITY AS s(segment, segment_ord)
  LEFT JOIN message_images mi
    ON mi.message_id = m.message_id
   AND mi.seg_index = segment_ord - 1
 WHERE m.source_platform = 'qq'
   AND m.message_origin = 'inbound'
   AND segment->>'type' = 'image'
   AND COALESCE(NULLIF(segment->'data'->>'url', ''), NULLIF(segment->'data'->>'file', '')) IS NOT NULL
   AND mi.message_id IS NULL
ON CONFLICT (kind, dedupe_key) DO NOTHING;
