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
