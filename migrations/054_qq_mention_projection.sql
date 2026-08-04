-- The canonical-platform cutover kept QQ mentions structurally in
-- canonical_content, but let the platform-neutral renderer project them as
-- plain @123 text.  Max's QQ prompt contract deliberately uses [@#123]: it is
-- unambiguous, maps through the member roster, and can round-trip to SegAt.
--
-- Rewrite only rows that still equal the old generic projection.  This leaves
-- intentional rendered_text overrides (notably stripped !btw/!feedback
-- conversation) untouched.
WITH projections AS (
    SELECT m.canonical_message_id,
           string_agg(
               CASE part->>'type'
                   WHEN 'text' THEN COALESCE(part->>'text', '')
                   WHEN 'mention' THEN '@' || COALESCE(part->>'display', part->>'native_user_id', '')
                   WHEN 'media' THEN COALESCE(NULLIF(btrim(part->>'caption'), ''), '[media]')
                   WHEN 'unsupported' THEN '[unsupported: ' || COALESCE(part->>'description', '') || ']'
                   ELSE ''
               END,
               ' ' ORDER BY part_ord
           ) AS generic_text,
           string_agg(
               CASE part->>'type'
                   WHEN 'text' THEN COALESCE(part->>'text', '')
                   WHEN 'mention' THEN '[@#' || COALESCE(part->>'native_user_id', '') || ']'
                   WHEN 'media' THEN COALESCE(NULLIF(btrim(part->>'caption'), ''), '[media]')
                   WHEN 'unsupported' THEN '[unsupported: ' || COALESCE(part->>'description', '') || ']'
                   ELSE ''
               END,
               ' ' ORDER BY part_ord
           ) AS qq_text
      FROM messages m
      CROSS JOIN LATERAL jsonb_array_elements(m.canonical_content)
          WITH ORDINALITY AS p(part, part_ord)
     WHERE m.source_platform = 'qq'
       AND m.message_origin = 'inbound'
       AND EXISTS (
           SELECT 1
             FROM jsonb_array_elements(m.canonical_content) mention
            WHERE mention->>'type' = 'mention'
       )
     GROUP BY m.canonical_message_id
)
UPDATE messages m
   SET rendered_text = p.qq_text
  FROM projections p
 WHERE m.canonical_message_id = p.canonical_message_id
   AND m.rendered_text = p.generic_text
   AND p.qq_text IS DISTINCT FROM p.generic_text;
