-- ADR 003 gave every non-message platform event a home in the ledger and
-- then filed all of them under 'debug', because at the time the only
-- question being asked was "does a prompt reader select this".  That answer
-- was no, so one word covered two unrelated populations:
--
--     965 + 111 rows  message/legacy + message/outbound   max's own tool
--                                                         traces — nobody in
--                                                         the room saw them
--     391 rows        reaction/internal                   max's own 贴表情
--      31 rows        redaction/inbound                   somebody 撤回了
--      17 rows        reaction/inbound                    somebody 贴表情
--       1 row         membership/inbound                  an unrenderable
--                                                         message
--
-- The bottom four are things every member of the room watched happen, and
-- hiding them made max the only participant who missed them.  'system' names
-- that population: the room saw it, so the model may read it, and it still
-- never triggers a reply.
--
-- Existing rows are deliberately left alone.  Their 'debug' classification
-- was accurate under the vocabulary they were written with, and the only way
-- to promote them would be to invent the rendered_text they were never given
-- — a fabricated transcript line is worse than an absent one.  New events
-- carry the new classification; the window moves past the old ones.
ALTER TABLE messages DROP CONSTRAINT messages_kind_check;

ALTER TABLE messages
  ADD CONSTRAINT messages_kind_check
  CHECK (kind = ANY (ARRAY['chat'::text, 'command'::text, 'system'::text, 'debug'::text]));
