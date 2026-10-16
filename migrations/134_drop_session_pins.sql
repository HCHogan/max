-- Pins are retired: neither !pin nor pin_message exists any more, and the
-- prompt no longer renders a [pinned] block or ranks pinned recall hits.
ALTER TABLE sessions DROP COLUMN pinned;
