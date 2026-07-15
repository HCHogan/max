-- Sticker library: stickers the bot has seen in chat, to be captioned
-- by a vision model (description IS NULL = caption pending), embedded
-- for retrieval (embedding IS NULL = embed pending), and eventually
-- sent back via the send_sticker tool.
--
-- kind 'custom' = a saved 动画表情 (image segment with sub_type=1;
-- resent the same way).  kind 'mface' = a marketplace 商城表情 — those
-- need emoji_id / emoji_package_id / mface_key to resend natively.
--
-- Untyped vector column for the same reason as 012_embeddings.sql.
CREATE TABLE stickers (
    sha256           text        PRIMARY KEY REFERENCES images(sha256) ON DELETE CASCADE,
    kind             text        NOT NULL CHECK (kind IN ('custom', 'mface')),
    emoji_id         text,
    emoji_package_id text,
    mface_key        text,
    summary          text,       -- NapCat's own label, e.g. [贴贴]
    description      text,       -- vision-model caption; NULL = pending
    caption_attempts int         NOT NULL DEFAULT 0,  -- failed caption tries; capped so a poison row can't loop the worker
    banned           boolean     NOT NULL DEFAULT false,
    times_seen       int         NOT NULL DEFAULT 1,
    times_sent       int         NOT NULL DEFAULT 0,
    first_group_id   bigint,
    first_seen_at    timestamptz NOT NULL DEFAULT now(),
    last_seen_at     timestamptz NOT NULL DEFAULT now(),
    embedding        vector
);

CREATE INDEX stickers_uncaptioned_idx
    ON stickers (first_seen_at)
    WHERE description IS NULL AND NOT banned AND caption_attempts < 5;

CREATE INDEX stickers_unembedded_idx
    ON stickers (first_seen_at)
    WHERE embedding IS NULL AND description IS NOT NULL AND NOT banned;

-- Backfill 1: marketplace faces.  mface segments persisted through
-- SegOther keep their full data object, so everything needed to
-- resend is already in messages.segments; message_images links the
-- downloaded bytes by (message_id, seg_index) — jsonb ordinality is
-- 1-based, seg_index 0-based.
INSERT INTO stickers
    (sha256, kind, emoji_id, emoji_package_id, mface_key, summary,
     times_seen, first_group_id, first_seen_at, last_seen_at)
SELECT s.sha256, 'mface',
       min(s.emoji_id), min(s.emoji_package_id), min(s.mface_key), min(s.summary),
       count(*), min(s.group_id), min(s.received_at), max(s.received_at)
FROM (
    SELECT mi.sha256,
           seg.value->'data'->>'emoji_id'         AS emoji_id,
           seg.value->'data'->>'emoji_package_id' AS emoji_package_id,
           seg.value->'data'->>'key'              AS mface_key,
           seg.value->'data'->>'summary'          AS summary,
           m.group_id, m.received_at
    FROM messages m
    CROSS JOIN LATERAL jsonb_array_elements(m.segments) WITH ORDINALITY AS seg(value, ord)
    JOIN message_images mi
      ON mi.message_id = m.message_id AND mi.seg_index = seg.ord - 1
    WHERE seg.value->>'type' = 'mface'
) s
GROUP BY s.sha256
ON CONFLICT (sha256) DO NOTHING;

-- Backfill 2: saved stickers.  Historical rows persisted image
-- segments through the old parser, which dropped sub_type — but the
-- CQ-code raw_message still has it.  Only single-image messages are
-- safe to attribute (no seg_index alignment through raw text).
INSERT INTO stickers
    (sha256, kind, times_seen, first_group_id, first_seen_at, last_seen_at)
SELECT s.sha256, 'custom', count(*), min(s.group_id), min(s.received_at), max(s.received_at)
FROM (
    SELECT mi.sha256, m.group_id, m.received_at
    FROM messages m
    JOIN message_images mi ON mi.message_id = m.message_id
    WHERE m.raw_message LIKE '%[CQ:image%sub_type=1%'
      AND (SELECT count(*) FROM message_images mi2
           WHERE mi2.message_id = m.message_id) = 1
) s
GROUP BY s.sha256
ON CONFLICT (sha256) DO NOTHING;
