-- Context ranges hash the canonical ledger, including semantic relations.
-- The old function encoded OneBot segments and the removed forward column,
-- so it was both platform-specific and invalid after the atomic cutover.

CREATE OR REPLACE FUNCTION conversation_source_hash(
    source_conversation_id bigint,
    source_start_seq bigint,
    source_end_seq bigint
)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT encode(
        digest(
            convert_to(
                COALESCE(
                    jsonb_agg(
                        jsonb_build_array(
                            m.ingest_seq,
                            m.canonical_message_id,
                            m.message_id,
                            m.author_principal_id,
                            to_char(
                                m.occurred_at AT TIME ZONE 'UTC',
                                'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
                            ),
                            m.canonical_content,
                            m.reply_to_canonical_message_id,
                            m.message_origin,
                            m.event_kind,
                            m.kind,
                            COALESCE((
                                SELECT jsonb_agg(
                                    jsonb_build_array(
                                        relation.relation_kind,
                                        relation.target_canonical_message_id,
                                        relation.target_native_event_id,
                                        relation.reaction_key,
                                        relation.reaction_added,
                                        relation.relation_position
                                    ) ORDER BY relation.relation_kind,
                                               relation.target_canonical_message_id,
                                               relation.target_native_event_id,
                                               relation.reaction_key,
                                               relation.reaction_added,
                                               relation.relation_position
                                )
                                FROM message_relations relation
                                WHERE relation.canonical_message_id = m.canonical_message_id
                            ), '[]'::jsonb)
                        ) ORDER BY m.ingest_seq
                    ),
                    '[]'::jsonb
                )::text,
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    )
    FROM messages AS m
    JOIN conversations conversation USING (conversation_id)
    WHERE conversation.legacy_group_id = source_conversation_id
      AND m.ingest_seq BETWEEN source_start_seq AND source_end_seq;
$$;
