-- ADR 004: make canonical_message_id the message identity, everywhere.
--
-- ADR 003 introduced canonical_message_id and moved the reference graph onto
-- it, but four tables and the primary-key declaration stayed behind on the
-- pre-ADR-003 compatibility id. That split is what let the model be handed an
-- identifier no other consumer uses -- and one whose *numeric shape* names the
-- transport, because message_id is minted three different ways (QQ numerics
-- pass through, bot messages take a synthetic negative, everything else is
-- minted in platform_ids).
--
-- This migration finishes the move. Afterwards message_id is an alternate key
-- serving the session/command/admin plumbing ADR 003 deliberately left alone,
-- and a later "REFERENCES messages" with no column list binds to the canonical
-- id, so a new table cannot pick the wrong one by default.
--
-- The two id spaces are 1:1 (both are unique, non-null columns of the same
-- row), so every backfill below is a join against messages on the same row and
-- there is no ambiguity anywhere.
--
-- Ordering matters: the straggler tables move first, so the primary-key flip at
-- the end is a key swap rather than two rounds of foreign-key surgery.
--
-- After deploying, run `max-adr003-maintenance reproject`: rendered_text is a
-- projection, and mention tokens in it still spell the old vocabulary.

--------------------------------------------------------------------------------
-- 1. message_images / message_videos: media is keyed by (message, position),
--    it was only keyed off the wrong message id. These primary keys are what
--    ADR 004 hands the model as [image#<canonical>.<seg>].

ALTER TABLE message_images ADD COLUMN canonical_message_id bigint;

UPDATE message_images AS link
   SET canonical_message_id = m.canonical_message_id
  FROM messages AS m
 WHERE m.message_id = link.message_id;

ALTER TABLE message_images ALTER COLUMN canonical_message_id SET NOT NULL;
ALTER TABLE message_images DROP CONSTRAINT message_images_message_id_fkey;
ALTER TABLE message_images DROP CONSTRAINT message_images_pkey;
ALTER TABLE message_images DROP COLUMN message_id;
ALTER TABLE message_images
  ADD CONSTRAINT message_images_pkey PRIMARY KEY (canonical_message_id, seg_index);
ALTER TABLE message_images
  ADD CONSTRAINT message_images_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;

ALTER TABLE message_videos ADD COLUMN canonical_message_id bigint;

UPDATE message_videos AS link
   SET canonical_message_id = m.canonical_message_id
  FROM messages AS m
 WHERE m.message_id = link.message_id;

ALTER TABLE message_videos ALTER COLUMN canonical_message_id SET NOT NULL;
ALTER TABLE message_videos DROP CONSTRAINT message_videos_message_id_fkey;
ALTER TABLE message_videos DROP CONSTRAINT message_videos_pkey;
ALTER TABLE message_videos DROP COLUMN message_id;
ALTER TABLE message_videos
  ADD CONSTRAINT message_videos_pkey PRIMARY KEY (canonical_message_id, seg_index);
ALTER TABLE message_videos
  ADD CONSTRAINT message_videos_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;

--------------------------------------------------------------------------------
-- 2. compartment_evidence: append-only by trigger, so the column swap is DDL
--    plus one guarded backfill.
--
--    Disabling the trigger for the length of this transaction is not a
--    weakening of the append-only rule. That rule exists so the application
--    cannot retract an audit row -- "this compartment was summarised from that
--    message" -- and re-expressing the *same* fact under the row's other unique
--    key retracts nothing. Nothing else may write here while we hold the lock.

ALTER TABLE compartment_evidence DISABLE TRIGGER compartment_evidence_append_only;

ALTER TABLE compartment_evidence ADD COLUMN source_canonical_message_id bigint;

UPDATE compartment_evidence AS evidence
   SET source_canonical_message_id = m.canonical_message_id
  FROM messages AS m
 WHERE m.message_id = evidence.source_message_id;

ALTER TABLE compartment_evidence ALTER COLUMN source_canonical_message_id SET NOT NULL;
ALTER TABLE compartment_evidence DROP CONSTRAINT compartment_evidence_source_message_id_fkey;
ALTER TABLE compartment_evidence DROP CONSTRAINT compartment_evidence_pkey;
DROP INDEX compartment_evidence_message_idx;
ALTER TABLE compartment_evidence DROP COLUMN source_message_id;
ALTER TABLE compartment_evidence
  ADD CONSTRAINT compartment_evidence_pkey
  PRIMARY KEY (compartment_id, summary_tier, source_canonical_message_id);
CREATE INDEX compartment_evidence_message_idx
  ON compartment_evidence (source_canonical_message_id, compartment_id);
ALTER TABLE compartment_evidence
  ADD CONSTRAINT compartment_evidence_source_message_fk
  FOREIGN KEY (source_canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE RESTRICT;

ALTER TABLE compartment_evidence ENABLE TRIGGER compartment_evidence_append_only;

--------------------------------------------------------------------------------
-- 3. memory_evidence: same treatment, and it finally gains the foreign key it
--    never had. RESTRICT rather than SET NULL because the row's own check
--    constraint requires the column when evidence_kind = 'message': a delete
--    that orphaned the evidence would have to destroy the evidence row too,
--    which is exactly what the append-only trigger forbids.

ALTER TABLE memory_evidence DISABLE TRIGGER memory_evidence_append_only;

ALTER TABLE memory_evidence RENAME COLUMN source_message_id TO source_canonical_message_id;

UPDATE memory_evidence AS evidence
   SET source_canonical_message_id = m.canonical_message_id
  FROM messages AS m
 WHERE m.message_id = evidence.source_canonical_message_id;

ALTER TABLE memory_evidence
  ADD CONSTRAINT memory_evidence_source_message_fk
  FOREIGN KEY (source_canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE RESTRICT;

ALTER TABLE memory_evidence ENABLE TRIGGER memory_evidence_append_only;

--------------------------------------------------------------------------------
-- 4. group_files. ADR 004 counted three stragglers by walking the foreign-key
--    graph; this one has no foreign key, which is precisely why the audit
--    missed it. It is the same defect: a table keyed off the wrong message id.

ALTER TABLE group_files ADD COLUMN canonical_message_id bigint;

UPDATE group_files AS f
   SET canonical_message_id = m.canonical_message_id
  FROM messages AS m
 WHERE m.message_id = f.message_id;

ALTER TABLE group_files DROP COLUMN message_id;
ALTER TABLE group_files
  ADD CONSTRAINT group_files_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE SET NULL;
CREATE INDEX group_files_message_idx
  ON group_files (canonical_message_id) WHERE canonical_message_id IS NOT NULL;

--------------------------------------------------------------------------------
-- 5. Complete the canonical reply column before anything reads it as the
--    authority. Rows left behind are legacy backfill quoting messages that
--    were never in the ledger: there is nothing to point them at, and
--    get_message_by_id has always returned null for them.

UPDATE messages AS m
   SET reply_to_canonical_message_id = target.canonical_message_id
  FROM messages AS target
 WHERE m.reply_to_canonical_message_id IS NULL
   AND m.reply_to_message_id IS NOT NULL
   AND target.message_id = m.reply_to_message_id;

--------------------------------------------------------------------------------
-- 6. Stored media handles inside canonical bodies. Inbound media never stored
--    one -- the handle is synthesized at render time -- so this touches only
--    bot-authored image resends, two rows in the whole ledger. It is written
--    as a general rewrite anyway, because "two rows" is a fact about today.

UPDATE messages AS m
   SET canonical_content = jsonb_set(
         m.canonical_content,
         '{nodes}',
         (
           SELECT coalesce(jsonb_agg(rewritten ORDER BY ord), '[]'::jsonb)
             FROM (
               SELECT ord,
                      CASE
                        WHEN node #> '{raw,source_message_id}' IS NULL THEN node
                        ELSE jsonb_set(
                               node,
                               '{raw,source_message_id}',
                               to_jsonb(coalesce(
                                 (SELECT src.canonical_message_id FROM messages AS src
                                   WHERE src.message_id = (node #>> '{raw,source_message_id}')::bigint),
                                 (node #>> '{raw,source_message_id}')::bigint
                               ))
                             )
                      END AS rewritten
                 FROM jsonb_array_elements(m.canonical_content -> 'nodes')
                      WITH ORDINALITY AS element(node, ord)
             ) AS rewritten_nodes
         )
       )
 WHERE EXISTS (
         SELECT 1 FROM jsonb_array_elements(m.canonical_content -> 'nodes') AS element(node)
          WHERE node #> '{raw,source_message_id}' IS NOT NULL
       );

--------------------------------------------------------------------------------
-- 7. Pins are a model-facing handle list stored as text; move them with
--    everything else rather than leaving one array speaking the old id space.

UPDATE sessions AS s
   SET pinned = coalesce(
         (
           SELECT jsonb_agg(to_jsonb(m.canonical_message_id) ORDER BY pin.ord)
             FROM jsonb_array_elements_text(s.pinned) WITH ORDINALITY AS pin(value, ord)
             JOIN messages AS m ON m.message_id = pin.value::bigint
         ),
         '[]'::jsonb
       )
 WHERE s.pinned <> '[]'::jsonb;

--------------------------------------------------------------------------------
-- 7b. A reminder's @-mention has to name a person, because it fires long
--     after the dispatch that created it and the account list may have moved
--     underneath it. The old column held a compatibility user id, which is
--     only resolvable back to a person by going through platform_ids.
--
--     Nullable, and deliberately not backfilled with a guess: a reminder we
--     cannot attribute to a principal degrades to plain text, which is
--     honest, where a wrong principal would @ the wrong human.

ALTER TABLE reminders ADD COLUMN author_principal_id bigint
  REFERENCES principals(principal_id) ON DELETE SET NULL;

UPDATE reminders AS r
   SET author_principal_id = resolved.principal_id
  FROM (
    SELECT reminder.id, identity.principal_id
      FROM reminders AS reminder
      JOIN conversations AS c ON c.legacy_group_id = reminder.group_id
      JOIN conversation_endpoints AS e ON e.conversation_id = c.conversation_id
      JOIN platform_accounts AS a ON a.platform_account_id = e.platform_account_id
      JOIN principal_identities AS identity
        ON identity.platform_account_id = a.platform_account_id
       AND identity.native_user_id = coalesce(
             (SELECT mapping.native_id FROM platform_ids AS mapping
               WHERE mapping.platform = a.platform AND mapping.kind = 'user'
                 AND mapping.mapped_id = reminder.user_id),
             reminder.user_id::text)
  ) AS resolved
 WHERE resolved.id = r.id;

ALTER TABLE reminders DROP COLUMN user_id;

--------------------------------------------------------------------------------
-- 8. The primary key. Nothing references message_id any more, so this is a key
--    swap: the existing unique index on canonical_message_id becomes the
--    primary key, and message_id keeps a unique constraint of its own.
--
--    The five foreign keys already pointing at canonical_message_id are dropped
--    and recreated because each depends on the specific index backing
--    messages_canonical_message_id_key, and reusing that index for the primary
--    key is what keeps this from leaving a duplicate behind.

ALTER TABLE platform_events DROP CONSTRAINT platform_events_canonical_message_fk;
ALTER TABLE message_relations DROP CONSTRAINT message_relations_message_fk;
ALTER TABLE message_relations DROP CONSTRAINT message_relations_target_fk;
ALTER TABLE message_deliveries DROP CONSTRAINT message_deliveries_message_fk;
ALTER TABLE message_dispatches DROP CONSTRAINT message_dispatches_message_fk;
ALTER TABLE messages DROP CONSTRAINT messages_reply_to_canonical_fk;
ALTER TABLE message_images DROP CONSTRAINT message_images_message_fk;
ALTER TABLE message_videos DROP CONSTRAINT message_videos_message_fk;
ALTER TABLE compartment_evidence DROP CONSTRAINT compartment_evidence_source_message_fk;
ALTER TABLE memory_evidence DROP CONSTRAINT memory_evidence_source_message_fk;
ALTER TABLE group_files DROP CONSTRAINT group_files_message_fk;

ALTER TABLE messages DROP CONSTRAINT messages_pkey;
ALTER TABLE messages DROP CONSTRAINT messages_canonical_message_id_key;
ALTER TABLE messages ADD CONSTRAINT messages_pkey PRIMARY KEY (canonical_message_id);
ALTER TABLE messages ADD CONSTRAINT messages_message_id_key UNIQUE (message_id);

ALTER TABLE platform_events
  ADD CONSTRAINT platform_events_canonical_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;
ALTER TABLE message_relations
  ADD CONSTRAINT message_relations_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;
ALTER TABLE message_relations
  ADD CONSTRAINT message_relations_target_fk
  FOREIGN KEY (target_canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE SET NULL;
ALTER TABLE message_deliveries
  ADD CONSTRAINT message_deliveries_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;
ALTER TABLE message_dispatches
  ADD CONSTRAINT message_dispatches_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;
ALTER TABLE messages
  ADD CONSTRAINT messages_reply_to_canonical_fk
  FOREIGN KEY (reply_to_canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE SET NULL;
ALTER TABLE message_images
  ADD CONSTRAINT message_images_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;
ALTER TABLE message_videos
  ADD CONSTRAINT message_videos_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE CASCADE;
ALTER TABLE compartment_evidence
  ADD CONSTRAINT compartment_evidence_source_message_fk
  FOREIGN KEY (source_canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE RESTRICT;
ALTER TABLE memory_evidence
  ADD CONSTRAINT memory_evidence_source_message_fk
  FOREIGN KEY (source_canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE RESTRICT;
ALTER TABLE group_files
  ADD CONSTRAINT group_files_message_fk
  FOREIGN KEY (canonical_message_id) REFERENCES messages(canonical_message_id) ON DELETE SET NULL;

--------------------------------------------------------------------------------
-- 9. conversation_source_hash reads canonical_content and
--    reply_to_canonical_message_id, both of which steps 5 and 6 rewrote. Every
--    stored hash over an affected range now describes an input set that no
--    longer exists, which the integrity check and episode expansion would both
--    report as drift. Re-stamp, exactly as 065 did for the same reason.

UPDATE conversation_compartments AS compartment
   SET source_hash = public.conversation_source_hash(
         compartment.conversation_id,
         compartment.start_ingest_seq,
         compartment.end_ingest_seq
       )
 WHERE compartment.source_hash IS DISTINCT FROM public.conversation_source_hash(
         compartment.conversation_id,
         compartment.start_ingest_seq,
         compartment.end_ingest_seq
       );

--------------------------------------------------------------------------------
-- 10. The columns that already claimed to hold principals.
--
--     `compartment_evidence.source_principal_id`, `memory_evidence`'s and
--     `memory_mutations`' equivalents, and `memories.scope_id` under user
--     scope have all been storing compatibility *user* ids since they were
--     written -- the writers passed `messages.user_id` into a column named
--     for a principal. Nothing broke because nothing ever joined them to
--     `principals`; the name was simply wrong.
--
--     ADR 004 makes that untenable: the historian now cites principals, so a
--     memory proposal's subject and a summary's evidence would disagree about
--     which id space they are in, and every user-scope proposal would be
--     rejected. Same defect class as everything else in this migration -- one
--     entity under two names -- so it moves with them.

-- 10a. A person who has a memory but no identity is a person the ledger never
--      saw speak. The account is real (the memory names it, and the
--      conversation it came from has exactly one platform account), so give it
--      the identity it should always have had rather than dropping the memory.

DO $$
DECLARE
  candidate record;
  fresh_principal bigint;
BEGIN
  FOR candidate IN
    SELECT DISTINCT
           account.platform_account_id AS platform_account_id,
           coalesce(
             (SELECT mapping.native_id FROM platform_ids AS mapping
               WHERE mapping.platform = account.platform AND mapping.kind = 'user'
                 AND mapping.mapped_id = memory.scope_id),
             memory.scope_id::text
           ) AS native_user_id
      FROM memories AS memory
      JOIN conversations AS c ON c.legacy_group_id = memory.source_group_id
      JOIN conversation_endpoints AS e ON e.conversation_id = c.conversation_id
      JOIN platform_accounts AS account ON account.platform_account_id = e.platform_account_id
     WHERE memory.scope = 'user'
  LOOP
    INSERT INTO principals (display_name) VALUES (NULL) RETURNING principal_id INTO fresh_principal;
    INSERT INTO principal_identities (principal_id, platform_account_id, native_user_id)
      VALUES (fresh_principal, candidate.platform_account_id, candidate.native_user_id)
      ON CONFLICT (platform_account_id, native_user_id) DO NOTHING;
    IF NOT FOUND THEN
      DELETE FROM principals WHERE principal_id = fresh_principal;
    END IF;
  END LOOP;
END $$;

-- 10b. compatibility user id -> principal, derived exactly the way
--      `Max.Platform.Store.compatibilityId` mints it: a numeric QQ native
--      passes through, everything else went through platform_ids.

CREATE TEMP TABLE compat_principal ON COMMIT DROP AS
SELECT DISTINCT ON (compat_user_id) compat_user_id, principal_id
  FROM (
    SELECT
      CASE
        WHEN account.platform = 'qq' AND identity.native_user_id ~ '^[0-9]+$'
          THEN identity.native_user_id::bigint
        ELSE (SELECT mapping.mapped_id FROM platform_ids AS mapping
               WHERE mapping.platform = account.platform AND mapping.kind = 'user'
                 AND mapping.native_id = identity.native_user_id)
      END AS compat_user_id,
      identity.principal_id
      FROM principal_identities AS identity
      JOIN platform_accounts AS account USING (platform_account_id)
  ) AS resolved
 WHERE compat_user_id IS NOT NULL
 ORDER BY compat_user_id, principal_id;

CREATE UNIQUE INDEX ON compat_principal (compat_user_id);

-- Refuse to run rather than leave one of these columns half-converted: a
-- mixed id space here is exactly the failure this migration exists to end.
DO $$
DECLARE stranded bigint;
BEGIN
  SELECT count(*) INTO stranded
    FROM memories AS memory
   WHERE memory.scope = 'user'
     AND NOT EXISTS (SELECT 1 FROM compat_principal AS t WHERE t.compat_user_id = memory.scope_id);
  IF stranded > 0 THEN
    RAISE EXCEPTION 'ADR 004: % user-scope memories name a compatibility id with no principal', stranded;
  END IF;
END $$;

UPDATE memories AS memory
   SET scope_id = t.principal_id
  FROM compat_principal AS t
 WHERE memory.scope = 'user' AND memory.scope_id = t.compat_user_id;

ALTER TABLE compartment_evidence DISABLE TRIGGER compartment_evidence_append_only;
ALTER TABLE memory_evidence DISABLE TRIGGER memory_evidence_append_only;
ALTER TABLE memory_mutations DISABLE TRIGGER memory_mutations_append_only;

UPDATE compartment_evidence AS evidence
   SET source_principal_id = t.principal_id
  FROM compat_principal AS t
 WHERE evidence.source_principal_id = t.compat_user_id;

UPDATE memory_evidence AS evidence
   SET source_principal_id = t.principal_id
  FROM compat_principal AS t
 WHERE evidence.source_principal_id = t.compat_user_id;

UPDATE memory_mutations AS mutation
   SET actor_principal_id = t.principal_id
  FROM compat_principal AS t
 WHERE mutation.actor_principal_id = t.compat_user_id;

ALTER TABLE compartment_evidence
  ADD CONSTRAINT compartment_evidence_source_principal_fk
  FOREIGN KEY (source_principal_id) REFERENCES principals(principal_id) ON DELETE RESTRICT;
ALTER TABLE memory_evidence
  ADD CONSTRAINT memory_evidence_source_principal_fk
  FOREIGN KEY (source_principal_id) REFERENCES principals(principal_id) ON DELETE RESTRICT;
ALTER TABLE memory_mutations
  ADD CONSTRAINT memory_mutations_actor_principal_fk
  FOREIGN KEY (actor_principal_id) REFERENCES principals(principal_id) ON DELETE RESTRICT;

ALTER TABLE compartment_evidence ENABLE TRIGGER compartment_evidence_append_only;
ALTER TABLE memory_evidence ENABLE TRIGGER memory_evidence_append_only;
ALTER TABLE memory_mutations ENABLE TRIGGER memory_mutations_append_only;
