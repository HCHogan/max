-- imsg 0.13.5 names the native Messages attachment source
-- `original_path` (and may repeat a tilde path as `filename`). An earlier Max
-- bridge only recognized `path`, so those host-local paths could survive in
-- diagnostic raw provenance even though canonical content stayed bounded.
-- Remove all path-bearing compatibility spellings; `transfer_name`, MIME,
-- size, UTI, and the canonical BlobStore projection remain available.

UPDATE platform_events event
SET raw_payload = jsonb_set(
  event.raw_payload,
  '{attachments}',
  COALESCE(
    (
      SELECT jsonb_agg(
        attachment.value - 'path' - 'original_path' - 'filename'
        ORDER BY attachment.ordinality)
      FROM jsonb_array_elements(event.raw_payload->'attachments')
        WITH ORDINALITY AS attachment(value, ordinality)
    ),
    '[]'::jsonb),
  false)
FROM conversation_endpoints endpoint
JOIN platform_accounts account USING (platform_account_id)
WHERE event.endpoint_id = endpoint.endpoint_id
  AND account.platform = 'imessage'
  AND jsonb_typeof(event.raw_payload->'attachments') = 'array'
  AND EXISTS (
    SELECT 1
    FROM jsonb_array_elements(event.raw_payload->'attachments') AS attachment(value)
    WHERE attachment.value ?| ARRAY['path', 'original_path', 'filename']);
