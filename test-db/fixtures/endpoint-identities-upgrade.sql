BEGIN;
INSERT INTO conversations(conversation_id,conversation_kind,legacy_group_id)
VALUES(970,'group',9970),(971,'group',9971);
INSERT INTO platform_accounts(platform_account_id,platform,native_account_id) VALUES(970,'qq','9700');
INSERT INTO conversation_endpoints(endpoint_id,conversation_id,platform_account_id,native_conversation_id,endpoint_kind,endpoint_mode)
VALUES(970,970,970,'9970','group','standalone'),(971,971,970,'9971','group','standalone');
INSERT INTO principals(principal_id,display_name)
VALUES(970,'self'),(971,'speaker'),(972,'mentioned'),(973,'poke'),(974,'foreign'),(975,'unseen');
INSERT INTO principal_identities(principal_identity_id,principal_id,platform_account_id,native_user_id)
SELECT identity,identity,970,native FROM (VALUES(970,'9700'),(971,'9701'),(972,'9702'),(973,'9703'),(974,'9704'),(975,'9705')) fixture(identity,native);
INSERT INTO messages(message_id,group_id,user_id,self_id,segments,rendered_text,canonical_message_id,canonical_content,
 conversation_id,conversation_seq,author_principal_id,origin_endpoint_id,source_native_event_id,occurred_at,message_origin,source_platform)
VALUES(970,9970,9701,9700,'[]','known mention',970,'{"v":2,"nodes":[{"type":"mention","identity":972,"display":"mentioned"}]}',970,1,971,970,'970',now(),'inbound','qq'),
 (971,9971,9704,9700,'[]','foreign speaker',971,'{"v":2,"nodes":[{"type":"text","text":"foreign speaker"}]}',971,1,974,971,'971',now(),'inbound','qq');
INSERT INTO agent_turns(turn_id,conversation_id,turn_ordinal,initiator_principal_id,status)
VALUES(970,970,1,973,'succeeded');
CREATE TEMP TABLE before_identity_messages AS SELECT * FROM messages;
\ir ../../migrations/097_endpoint_known_identities.sql
DO $$
BEGIN
  IF (SELECT array_agg(principal_identity_id ORDER BY principal_identity_id) FROM endpoint_known_identities WHERE endpoint_id=970)
     IS DISTINCT FROM ARRAY[970,971,972,973]::bigint[] THEN
    RAISE EXCEPTION 'sender, mention, poke or self evidence was lost, or an outsider leaked';
  END IF;
  IF (SELECT array_agg(principal_identity_id ORDER BY principal_identity_id) FROM endpoint_known_identities WHERE endpoint_id=971)
     IS DISTINCT FROM ARRAY[970,974]::bigint[] THEN
    RAISE EXCEPTION 'shared account expanded foreign endpoint visibility';
  END IF;
  IF EXISTS((SELECT * FROM messages EXCEPT SELECT * FROM before_identity_messages)
    UNION ALL (SELECT * FROM before_identity_messages EXCEPT SELECT * FROM messages)) THEN
    RAISE EXCEPTION 'identity projection rewrote canonical evidence';
  END IF;
END;
$$;
COMMIT;
SELECT '097 restored scoped identity evidence without rewriting messages' AS result;
