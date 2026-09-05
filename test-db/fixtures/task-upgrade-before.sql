BEGIN;
INSERT INTO conversations(conversation_id,conversation_kind,legacy_group_id) VALUES(1,'group',900);
INSERT INTO principals(principal_id,display_name) VALUES(1,'upgrade fixture');
INSERT INTO agent_turns(turn_id,conversation_id,turn_ordinal,initiator_principal_id,status)
VALUES(1,1,1,1,'running'),(2,1,2,1,'running'),(3,1,3,1,'recovery-pending'),(4,1,4,1,'running');
INSERT INTO plans(conversation_id,plan_ordinal,root_turn_id) VALUES(1,1,1),(1,2,2);
INSERT INTO plan_revisions(plan_id,revision,ir_version,plan_hash,document,cause)
VALUES(1,1,1,repeat('a',64),'{"legacy":true}','initial'),(2,1,1,repeat('b',64),'{"legacy":true}','initial');
INSERT INTO turn_edges(conversation_id,from_turn_id,to_turn_id,edge_kind,plan_id,goal_hash,dispatched_node_id)
VALUES(1,2,3,'spawn',2,repeat('c',64),'legacy-child');
INSERT INTO turn_edges(conversation_id,from_turn_id,to_turn_id,edge_kind) VALUES(1,1,4,'fork-from');
INSERT INTO durable_tasks(task_id,conversation_id,owner_principal_id,source_turn_id,admission_key,root_task_id,
  objective,profile,revision,status,attempt,calls_reserved,rounds_reserved,created_at,deadline)
VALUES(1,1,1,1,'existing-task',1,'live task','research',2,'running',1,17,20,now()-interval '2 minutes',now()+interval '8 minutes');
INSERT INTO durable_tasks(task_id,conversation_id,owner_principal_id,source_turn_id,admission_key,
  parent_task_id,parent_revision,root_task_id,objective,profile,deadline)
VALUES(2,1,1,4,'existing-child',1,2,1,'live child','research',now()+interval '8 minutes');
INSERT INTO task_revisions(task_id,revision,objective,author_principal_id)
VALUES(1,1,'original task',1),(1,2,'live task',1),(2,1,'live child',1);
INSERT INTO task_events(task_id,revision,kind,body) VALUES(1,2,'steer','keep this feedback');
INSERT INTO task_attempts(turn_id,task_id,revision,attempt,owner,lease_until)
VALUES(4,1,2,1,'existing-worker',now()+interval '60 seconds');
INSERT INTO execution_journal(turn_id,execution_ordinal,node_id,event_kind,state,tool_ref)
VALUES(1,1,'task-source','tool_call','started','task_start'),
      (3,1,'legacy-side-effect','tool_call','started','sandbox_exec'),
      (4,1,'task-side-effect','tool_call','started','web_search');
COMMIT;
