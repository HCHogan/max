-- Atomic ADR 003 cutover: after the offline v2/forward backfills, the final
-- binary accepts canonical writers only.  Keep the ledger's sequence default
-- trigger, but remove every branch that fabricated canonical state for a
-- legacy INSERT.

DROP TRIGGER messages_canonicalize_legacy_before ON messages;
DROP FUNCTION messages_canonicalize_legacy();

DROP TRIGGER messages_publish_legacy_source_after ON messages;
DROP FUNCTION messages_publish_legacy_source();

DROP TRIGGER zz_messages_set_source_platform_before ON messages;
DROP FUNCTION messages_set_source_platform();

CREATE FUNCTION messages_assign_canonical_sequence() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.conversation_id IS NULL
     OR NEW.author_principal_id IS NULL
     OR NEW.origin_endpoint_id IS NULL
     OR NEW.source_native_event_id IS NULL
     OR NEW.occurred_at IS NULL THEN
    RAISE EXCEPTION 'legacy message INSERT is disabled; canonical provenance is required';
  END IF;
  NEW.conversation_seq := COALESCE(NEW.conversation_seq, NEW.ingest_seq);
  RETURN NEW;
END;
$$;

CREATE TRIGGER messages_assign_canonical_sequence_before
BEFORE INSERT ON messages
FOR EACH ROW
EXECUTE FUNCTION messages_assign_canonical_sequence();

-- Non-QQ segment arrays were only a compatibility projection.  The final
-- runtime writes and reads canonical_content; QQ alone retains raw segment
-- provenance for same-platform round trips and media fetch evidence.
UPDATE messages SET segments = '[]'::jsonb WHERE source_platform <> 'qq';

ALTER TABLE messages
  ALTER COLUMN canonical_content DROP DEFAULT,
  ALTER COLUMN message_origin DROP DEFAULT,
  ALTER COLUMN source_platform DROP DEFAULT;

ALTER TABLE messages
  ADD CONSTRAINT messages_canonical_content_v2_check
  CHECK (
    jsonb_typeof(canonical_content) = 'object'
    AND canonical_content->>'v' = '2'
    AND jsonb_typeof(canonical_content->'nodes') = 'array'
  ),
  ADD CONSTRAINT messages_non_qq_segments_empty_check
  CHECK (source_platform = 'qq' OR segments = '[]'::jsonb);
