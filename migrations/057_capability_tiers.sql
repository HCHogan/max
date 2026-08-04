-- ADR 003 atomic cutover: rewrite every persisted capability manifest to the
-- sole tiered runtime schema.  Empty endpoint manifests intentionally remain
-- empty because they inherit their platform account's manifest.

CREATE OR REPLACE FUNCTION max_capability_tiers(old jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
  SELECT jsonb_strip_nulls(
    jsonb_build_object(
      'send_text', COALESCE((old->>'send_text')::boolean, false),
      'mention_tier', COALESCE(old->>'mention_tier', 'text'),
      'reply_tier', COALESCE(
        old->>'reply_tier',
        CASE WHEN COALESCE((old->>'reply')::boolean, false) THEN 'native' ELSE 'text' END
      ),
      'emote_tier', COALESCE(old->>'emote_tier', 'text'),
      'image_tier', COALESCE(
        old->>'image_tier',
        CASE WHEN COALESCE((old->>'send_media')::boolean, false) THEN 'native' ELSE 'text' END
      ),
      'sticker_tier', COALESCE(
        old->>'sticker_tier',
        CASE WHEN COALESCE((old->>'send_media')::boolean, false) THEN 'native' ELSE 'text' END
      ),
      'video_tier', COALESCE(
        old->>'video_tier',
        CASE WHEN COALESCE((old->>'send_media')::boolean, false) THEN 'native' ELSE 'text' END
      ),
      'audio_tier', COALESCE(
        old->>'audio_tier',
        CASE WHEN COALESCE((old->>'send_media')::boolean, false) THEN 'native' ELSE 'text' END
      ),
      'file_tier', COALESCE(
        old->>'file_tier',
        CASE WHEN COALESCE((old->>'send_media')::boolean, false) THEN 'native' ELSE 'text' END
      ),
      'card_tier', COALESCE(old->>'card_tier', 'text'),
      'reaction', COALESCE((old->>'reaction')::boolean, false),
      'edit', COALESCE((old->>'edit')::boolean, false),
      'redact', COALESCE((old->>'redact')::boolean, false),
      'max_text_bytes', old->'max_text_bytes',
      'max_native_media', COALESCE((old->>'max_native_media')::integer, 1)
    )
  )
$$;

UPDATE platform_accounts
SET capabilities = max_capability_tiers(capabilities);

UPDATE conversation_endpoints
SET capabilities = max_capability_tiers(capabilities)
WHERE capabilities <> '{}'::jsonb;

DROP FUNCTION max_capability_tiers(jsonb);
