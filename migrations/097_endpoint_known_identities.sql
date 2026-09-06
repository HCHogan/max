-- A platform account can serve many conversations. Identity ownership by that
-- account alone is not evidence that an endpoint knows the person.
CREATE TABLE endpoint_known_identities (
  endpoint_id bigint NOT NULL REFERENCES conversation_endpoints(endpoint_id) ON DELETE CASCADE,
  principal_identity_id bigint NOT NULL REFERENCES principal_identities(principal_identity_id) ON DELETE CASCADE,
  PRIMARY KEY (endpoint_id, principal_identity_id)
);
CREATE INDEX endpoint_known_identities_identity_idx ON endpoint_known_identities(principal_identity_id);

-- Reconstruct only relationships supported by durable conversation evidence.
-- Message senders, explicitly mentioned identities, turn initiators (including
-- contentless pokes), and the endpoint's own account are known participants.
INSERT INTO endpoint_known_identities(endpoint_id, principal_identity_id)
SELECT e.endpoint_id, pi.principal_identity_id
FROM conversation_endpoints e
JOIN platform_accounts a USING(platform_account_id)
JOIN principal_identities pi USING(platform_account_id)
WHERE pi.native_user_id=a.native_account_id
UNION
SELECT e.endpoint_id, pi.principal_identity_id
FROM messages m
JOIN conversation_endpoints e ON e.endpoint_id=m.origin_endpoint_id
JOIN principal_identities pi ON pi.platform_account_id=e.platform_account_id AND pi.principal_id=m.author_principal_id
UNION
SELECT e.endpoint_id, pi.principal_identity_id
FROM messages m
JOIN conversation_endpoints e ON e.conversation_id=m.conversation_id
CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(m.canonical_content->'nodes')='array' THEN m.canonical_content->'nodes' ELSE '[]'::jsonb END) node
JOIN principal_identities pi ON pi.platform_account_id=e.platform_account_id AND to_jsonb(pi.principal_identity_id)=node->'identity'
WHERE node->>'type'='mention'
UNION
SELECT e.endpoint_id, pi.principal_identity_id
FROM agent_turns turn
JOIN conversation_endpoints e USING(conversation_id)
JOIN principal_identities pi ON pi.platform_account_id=e.platform_account_id AND pi.principal_id=turn.initiator_principal_id
ON CONFLICT DO NOTHING;
