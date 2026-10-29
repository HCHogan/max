-- Made-up old rows. Max's old QQ number is 20000; 小明 20001, 小红 20002,
-- the owner 20003; the group is 10001.

insert into platform_accounts values
    (1, 'qq', '20000'),
    (2, 'imessage', 'max@example.com');

insert into principals (principal_id, display_name) values
    (1, 'Max'),
    (2, null),
    (3, null),
    (4, '主人'),
    -- Max on iMessage, and a principal with nothing: neither comes along.
    (5, 'Max'),
    (6, null);

insert into principal_identities values
    (11, 1, 1, '20000', 'Max'),
    (12, 2, 1, '20001', '小明'),
    (13, 3, 1, '20002', null),
    (14, 4, 1, '20003', null),
    (15, 5, 2, 'max@example.com', null);

insert into conversations (conversation_id, conversation_kind, title, legacy_group_id) values
    (100, 'group', '测试群', 10001),
    (101, 'direct', null, -20003),
    (102, 'direct', null, -20001),
    (103, 'group', 'iMessage 的群', null);

insert into conversation_endpoints values
    (200, 100, 1, '10001'),
    (201, 101, 1, 'user:20003'),
    -- The same private chat again, under the other form.
    (202, 101, 1, '-20003'),
    (203, 102, 1, '-20001'),
    (204, 103, 2, 'chat-1');

-- Messages in the group (100, endpoint 200) unless said otherwise. What
-- stays behind says so.
insert into messages (canonical_message_id, conversation_id, origin_endpoint_id,
    author_principal_id, source_platform, event_kind, kind, message_origin, is_synthetic,
    rendered_text, sender_nickname, sender_card, source_native_event_id, occurred_at,
    received_at, reply_to_canonical_message_id, canonical_content, ingest_seq) values
    (1001, 100, 200, 2, 'qq', 'message', 'chat', 'inbound', false, '大家好', '明哥', null, 'n1001',
     '2026-01-02 10:00+08', '2026-01-02 10:00:01+08', null,
     '{"v": 2, "nodes": [{"type": "text", "text": "大家好 "}, {"type": "mention", "display": "小红", "identity": 13}, {"type": "text", "text": " "}, {"type": "mention", "display": "Max", "identity": 15}]}', 1),
    (1002, 100, 200, 1, 'qq', 'message', 'chat', 'outbound', false, '你好', null, null, 'n1002',
     '2026-01-02 10:01+08', '2026-01-02 10:01+08', 1001,
     '{"v": 2, "nodes": [{"type": "text", "text": "你好"}]}', 2),
    -- Max's message seen again as inbound.
    (1003, 100, 200, 1, 'qq', 'message', 'chat', 'inbound', false, '你好', 'Max', null, 'n1003',
     '2026-01-02 10:01:02+08', '2026-01-02 10:01:02+08', null,
     '{"v": 2, "nodes": [{"type": "text", "text": "你好"}]}', 3),
    (1004, 100, 200, 3, 'qq', 'message', 'chat', 'legacy', false, '', '小红红', ' ', 'n1004',
     '2026-01-02 10:02+08', '2026-01-02 10:02+08', null,
     '{"v": 2, "nodes": [{"type": "emote", "platform": "qq", "native_id": "14", "name": "微笑"}, {"type": "card", "tag": "哔哩哔哩", "title": "视频"}, {"type": "unsupported", "source": "qq:record", "description": "语音"}]}', 4),
    (1005, 100, 200, 2, 'qq', 'message', 'command', 'inbound', false, '/status', '明哥', null, 'n1005',
     '2026-01-02 10:03+08', '2026-01-02 10:03+08', null,
     '{"v": 2, "nodes": [{"type": "text", "text": "/status"}]}', 5),
    (1006, 100, 200, 1, 'qq', 'message', 'command', 'outbound', false, '在跑', null, null, 'n1006',
     '2026-01-02 10:03:01+08', '2026-01-02 10:03:01+08', null,
     '{"v": 2, "nodes": [{"type": "text", "text": "在跑"}]}', 6),
    -- A reaction, a debug row, a [silence] record and a synthetic row.
    (1007, 100, 200, 2, 'qq', 'reaction', 'chat', 'inbound', false, '', null, null, 'n1007',
     '2026-01-02 10:04+08', '2026-01-02 10:04+08', null, '{"v": 2, "nodes": []}', 7),
    (1008, 100, 200, 1, 'qq', 'message', 'debug', 'outbound', false, '', null, null, 'n1008',
     '2026-01-02 10:04+08', '2026-01-02 10:04+08', null, '{"v": 2, "nodes": []}', 8),
    (1009, 100, 200, 1, 'qq', 'message', 'chat', 'internal', false, '', null, null, 'n1009',
     '2026-01-02 10:04+08', '2026-01-02 10:04+08', null, '{"v": 2, "nodes": []}', 9),
    (1010, 100, 200, 1, 'qq', 'message', 'chat', 'legacy', true, '', null, null, 'n1010',
     '2026-01-02 10:04+08', '2026-01-02 10:04+08', null, '{"v": 2, "nodes": []}', 10),
    -- A forward of two messages, the second a forward of one.
    (1011, 100, 200, 2, 'qq', 'message', 'chat', 'inbound', false, '', '明哥', null, 'n1011',
     '2026-01-02 10:05+08', '2026-01-02 10:05+08', null,
     '{"v": 2, "nodes": [{"type": "text", "text": "看这个"}, {"type": "forward", "native_id": "F1"}]}', 11),
    (1012, 100, 200, 6, 'qq', 'message', 'chat', 'inbound', false, '', '甲某', '甲', 'forward:1',
     '2020-01-01 00:00+08', '2026-01-02 10:05+08', null,
     '{"v": 2, "nodes": [{"type": "text", "text": "第一句"}, {"type": "media", "kind": "image", "source": "blob:aa"}]}', 12),
    (1013, 100, 200, 6, 'qq', 'message', 'chat', 'inbound', false, '', '乙', null, 'forward:2',
     '2020-01-01 00:00+08', '2026-01-02 10:05+08', null,
     '{"v": 2, "nodes": [{"type": "forward", "native_id": "F2"}]}', 13),
    (1014, 100, 200, 6, 'qq', 'message', 'chat', 'legacy', true, '', null, null, 'forward:3',
     '2020-01-01 00:00+08', '2026-01-02 10:05+08', null,
     '{"v": 2, "nodes": [{"type": "text", "text": "里面"}]}', 14),
    -- 小红 recalls 1001; the recall of the debug row stays behind.
    (1015, 100, 200, 3, 'qq', 'redaction', 'system', 'inbound', false, '', null, null, 'n1015',
     '2026-01-02 10:06+08', '2026-01-02 10:06+08', null, '{"v": 2, "nodes": []}', 15),
    (1016, 100, 200, 3, 'qq', 'redaction', 'system', 'inbound', false, '', null, null, 'n1016',
     '2026-01-02 10:06+08', '2026-01-02 10:06+08', null, '{"v": 2, "nodes": []}', 16),
    -- A reply to a later row, and one to a row that stays behind.
    (1017, 100, 200, 2, 'qq', 'message', 'chat', 'inbound', false, '', '明哥', null, 'n1017',
     '2026-01-02 10:07+08', '2026-01-02 10:07+08', 1018,
     '{"v": 2, "nodes": [{"type": "text", "text": "对"}]}', 17),
    (1018, 100, 200, 3, 'qq', 'message', 'chat', 'inbound', false, '', null, null, 'n1018',
     '2026-01-02 10:06:30+08', '2026-01-02 10:07+08', null,
     '{"v": 2, "nodes": [{"type": "text", "text": "后来的"}]}', 18),
    (1022, 100, 200, 2, 'qq', 'message', 'chat', 'inbound', false, '', '明哥', null, 'n1022',
     '2026-01-02 10:08+08', '2026-01-02 10:08+08', 1008,
     '{"v": 2, "nodes": [{"type": "text", "text": "啥"}]}', 22),
    -- The owner's private chat, through its other endpoint; then WeChat.
    (1019, 101, 202, 4, 'qq', 'message', 'chat', 'inbound', false, '', '主人', null, 'n1019',
     '2026-01-02 11:00+08', '2026-01-02 11:00+08', null,
     '{"v": 2, "nodes": [{"type": "text", "text": "在吗"}]}', 19),
    (1020, 103, 204, 5, 'wechat', 'message', 'chat', 'inbound', false, '', null, null, 'n1020',
     '2026-01-02 11:00+08', '2026-01-02 11:00+08', null,
     '{"v": 2, "nodes": [{"type": "text", "text": "微信"}]}', 20);

insert into message_relations values
    (1, 1012, 'contained_in', 1011, 0),
    (2, 1013, 'contained_in', 1011, 1),
    (3, 1014, 'contained_in', 1013, 0),
    (4, 1015, 'redacts', 1001, null),
    (5, 1016, 'redacts', 1008, null);

insert into platform_events values
    (1, 1001, 'message', '{"sender": {"role": "admin", "card": "明哥"}}'),
    (2, 1001, 'reaction', '{"other": true}'),
    (3, 1015, 'redaction', '{"recalled": "n1001"}');
