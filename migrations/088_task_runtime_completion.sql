CREATE TABLE retired_runtime_records (
  source text NOT NULL,
  identity text NOT NULL,
  data jsonb NOT NULL,
  archived_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(source,identity)
);
INSERT INTO retired_runtime_records SELECT 'plan',plan_id::text,to_jsonb(history),now() FROM plans history;
INSERT INTO retired_runtime_records SELECT 'plan_revision',plan_id||':'||revision,to_jsonb(history),now() FROM plan_revisions history;
INSERT INTO retired_runtime_records SELECT 'plan_spawn',edge_id::text,to_jsonb(history),now() FROM turn_edges history WHERE edge_kind='spawn';

DROP TRIGGER agent_turns_notify_plan_child_settled ON agent_turns;
DROP FUNCTION max_notify_plan_child_settled();
DROP FUNCTION max_notify_plan_child_cancelled() CASCADE;
DROP FUNCTION max_notify_plan_work() CASCADE;

UPDATE execution_journal SET state='outcome-unknown',finished_at=now(),failure_code='retired_execution',
  failure_detail='Plan runtime retired; inspect archived work before taking further action'
WHERE state='started' AND turn_id IN
  (SELECT to_turn_id FROM turn_edges WHERE edge_kind='spawn'
   UNION SELECT root_turn_id FROM plans WHERE status='open'
   UNION SELECT wake_turn_id FROM plans WHERE wake_turn_id IS NOT NULL)
AND NOT EXISTS (SELECT 1 FROM task_attempts execution WHERE execution.turn_id=execution_journal.turn_id)
AND NOT EXISTS (SELECT 1 FROM task_notifications notice WHERE notice.turn_id=execution_journal.turn_id)
AND NOT EXISTS (SELECT 1 FROM durable_tasks work WHERE work.source_turn_id=execution_journal.turn_id);
UPDATE agent_turns SET status='aborted',finished_at=now(),abort_reason='Plan runtime retired; work archived, not replayed'
WHERE status IN ('starting','running','recovery-pending') AND turn_id IN
  (SELECT to_turn_id FROM turn_edges WHERE edge_kind='spawn'
   UNION SELECT root_turn_id FROM plans WHERE status='open'
   UNION SELECT wake_turn_id FROM plans WHERE wake_turn_id IS NOT NULL)
AND NOT EXISTS (SELECT 1 FROM task_attempts execution WHERE execution.turn_id=agent_turns.turn_id)
AND NOT EXISTS (SELECT 1 FROM task_notifications notice WHERE notice.turn_id=agent_turns.turn_id)
AND NOT EXISTS (SELECT 1 FROM durable_tasks work WHERE work.source_turn_id=agent_turns.turn_id);
DELETE FROM turn_edges WHERE edge_kind='spawn';
DROP INDEX turn_edges_spawn_child_idx;
ALTER TABLE turn_edges
  DROP COLUMN plan_id CASCADE, DROP COLUMN goal_hash CASCADE, DROP COLUMN dispatched_node_id CASCADE,
  DROP COLUMN child_result CASCADE, DROP COLUMN child_goal CASCADE, DROP COLUMN child_view CASCADE,
  DROP COLUMN child_tool_grants CASCADE, DROP COLUMN child_inputs CASCADE,
  DROP COLUMN child_cancel_requested_at CASCADE, DROP COLUMN child_result_written_at CASCADE,
  DROP CONSTRAINT turn_edges_edge_kind_check,
  ADD CONSTRAINT turn_edges_edge_kind_check CHECK(edge_kind='fork-from');
DROP TABLE plan_revisions;
DROP TABLE plans;

ALTER TABLE durable_tasks
  DROP CONSTRAINT durable_tasks_objective_check,
  ADD CONSTRAINT durable_tasks_objective_check CHECK(length(objective) BETWEEN 1 AND 40000),
  DROP CONSTRAINT durable_tasks_max_calls_check,
  ADD CONSTRAINT durable_tasks_max_calls_check CHECK(max_calls BETWEEN 1 AND 600),
  DROP CONSTRAINT durable_tasks_max_rounds_check,
  ADD CONSTRAINT durable_tasks_max_rounds_check CHECK(max_rounds BETWEEN 1 AND 1200),
  DROP CONSTRAINT durable_tasks_status_check,
  ADD CONSTRAINT durable_tasks_status_check CHECK(status IN ('queued','running','waiting','retrying','succeeded','partial','failed','cancelled','budget_exhausted')),
  ALTER COLUMN max_calls SET DEFAULT 200,
  ALTER COLUMN max_rounds SET DEFAULT 400,
  ALTER COLUMN deadline SET DEFAULT (now()+interval '50 minutes'),
  ADD COLUMN retry_count integer NOT NULL DEFAULT 0,
  ADD COLUMN next_attempt_at timestamptz,
  ADD COLUMN last_error text;
ALTER TABLE task_events DROP CONSTRAINT task_events_body_check,
  ADD CONSTRAINT task_events_body_check CHECK(length(body)<=60000);
ALTER TABLE task_attempts ADD COLUMN retryable boolean NOT NULL DEFAULT false;
ALTER TABLE task_notifications ADD COLUMN kind text NOT NULL DEFAULT 'result' CHECK(kind IN ('result','progress')),
  ADD COLUMN created_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN next_attempt_at timestamptz NOT NULL DEFAULT now(),
  ADD COLUMN last_error text,
  ADD COLUMN superseded_at timestamptz;
ALTER TABLE conversation_requests DROP CONSTRAINT conversation_requests_disposition_check,
  ADD CONSTRAINT conversation_requests_disposition_check CHECK(disposition IN ('pending','delegated','answered','waiting','declined','failed','cancelled'));
CREATE TABLE request_outcomes (
  turn_id bigint PRIMARY KEY REFERENCES agent_turns ON DELETE CASCADE,
  disposition text NOT NULL CHECK(disposition IN ('answered','waiting','declined')),
  reply text NOT NULL CHECK(length(trim(reply)) BETWEEN 1 AND 40000),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE task_progress (
  task_id bigint PRIMARY KEY REFERENCES durable_tasks ON DELETE CASCADE,
  revision integer NOT NULL,
  attempt integer NOT NULL,
  version bigint NOT NULL DEFAULT 1,
  body jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE monitors DROP CONSTRAINT monitors_queue_limit_check,
  ADD CONSTRAINT monitors_queue_limit_check CHECK(queue_limit BETWEEN 1 AND 160),
  ALTER COLUMN queue_limit SET DEFAULT 40,
  ADD COLUMN task_profile text NOT NULL DEFAULT 'research' CHECK(task_profile IN ('research','browser','sandbox'));
UPDATE monitors SET queue_limit=queue_limit*5;
UPDATE monitor_fires fire SET definition_snapshot=fire.definition_snapshot || jsonb_build_object('profile','research','change_only',definition.change_only)
FROM monitors definition WHERE definition.monitor_id=fire.monitor_id;
UPDATE durable_tasks work SET max_calls=work.max_calls*5,max_rounds=work.max_rounds*5,
  deadline=root.created_at+(root.deadline-root.created_at)*5
FROM durable_tasks root WHERE root.task_id=COALESCE(work.root_task_id,work.task_id)
AND work.status IN ('queued','running','waiting');

CREATE OR REPLACE FUNCTION max_task_admit(source_turn bigint, source_message bigint, actor bigint,
  admission text, objective_text text, capability text, input_values jsonb, tool_grants jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  source agent_turns;
  parent durable_tasks;
  created durable_tasks;
  parent_id bigint;
BEGIN
  SELECT * INTO source FROM agent_turns WHERE turn_id=source_turn;
  PERFORM conversation_id FROM conversations WHERE conversation_id=source.conversation_id FOR UPDATE;
  SELECT * INTO source FROM agent_turns WHERE turn_id=source_turn FOR UPDATE;
  IF NOT FOUND OR source.status NOT IN ('starting','running','recovery-pending') THEN
    RETURN jsonb_build_object('error','source turn is no longer active');
  END IF;
  IF NOT max_task_authorize(source_turn,'task_start',false) THEN RETURN jsonb_build_object('error','source execution was fenced'); END IF;
  SELECT work.* INTO created FROM durable_tasks work WHERE work.admission_key=admission AND
    (work.source_turn_id=source_turn OR EXISTS (SELECT 1 FROM task_attempts execution WHERE execution.turn_id=source_turn
      AND execution.task_id=work.parent_task_id AND execution.revision=work.parent_revision));
  IF FOUND THEN RETURN to_jsonb(created); END IF;
  IF source.initiator_principal_id IS DISTINCT FROM actor OR length(admission) NOT BETWEEN 1 AND 600
    OR length(trim(objective_text)) NOT BETWEEN 1 AND 40000 OR octet_length(input_values::text)>160000
    OR capability NOT IN ('research','browser','sandbox') THEN
    RETURN jsonb_build_object('error','invalid task admission');
  END IF;
  IF source_message IS NOT NULL AND NOT EXISTS
    (SELECT 1 FROM messages WHERE canonical_message_id=source_message AND conversation_id=source.conversation_id) THEN
    RETURN jsonb_build_object('error','source message outside conversation');
  END IF;
  SELECT task_id INTO parent_id FROM task_attempts WHERE turn_id=source_turn;
  IF parent_id IS NOT NULL THEN
    SELECT * INTO parent FROM durable_tasks WHERE task_id=parent_id FOR UPDATE;
    IF parent.status<>'running' OR NOT EXISTS (SELECT 1 FROM task_attempts WHERE turn_id=source_turn
      AND revision=parent.revision AND attempt=parent.attempt AND lease_until>clock_timestamp()) THEN
      RETURN jsonb_build_object('error','parent execution was fenced');
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_each_text(tool_grants) grant_entry
      WHERE parent.grants->>grant_entry.key IS DISTINCT FROM grant_entry.value) THEN
      RETURN jsonb_build_object('error','child authority exceeds parent');
    END IF;
    IF (WITH RECURSIVE ancestors AS (SELECT task_id,parent_task_id FROM durable_tasks WHERE task_id=parent_id
      UNION ALL SELECT task.task_id,task.parent_task_id FROM durable_tasks task JOIN ancestors ON task.task_id=ancestors.parent_task_id)
      SELECT count(*) FROM ancestors)>15 THEN RETURN jsonb_build_object('error','task depth limit'); END IF;
  END IF;
  PERFORM conversation_id FROM conversations WHERE conversation_id=source.conversation_id FOR UPDATE;
  IF (SELECT count(*) FROM durable_tasks WHERE conversation_id=source.conversation_id AND status IN ('queued','running','waiting','retrying'))>=160 THEN
    RETURN jsonb_build_object('error','conversation task queue is full');
  END IF;
  INSERT INTO durable_tasks(conversation_id,owner_principal_id,source_turn_id,source_message_id,
    admission_key,parent_task_id,parent_revision,root_task_id,objective,profile,inputs,grants,deadline)
  VALUES(source.conversation_id,actor,source_turn,source_message,admission,parent_id,parent.revision,
    COALESCE(parent.root_task_id,parent.task_id),trim(objective_text),capability,input_values,tool_grants,
    LEAST(COALESCE(parent.deadline,now()+interval '50 minutes'),now()+interval '50 minutes')) RETURNING * INTO created;
  INSERT INTO task_revisions(task_id,revision,objective,author_principal_id) VALUES(created.task_id,1,created.objective,actor);
  IF source_message IS NOT NULL AND parent_id IS NULL THEN
    INSERT INTO conversation_requests(message_id,turn_id,disposition) VALUES(source_message,source_turn,'delegated')
      ON CONFLICT(message_id) DO UPDATE SET disposition='delegated',updated_at=now();
  END IF;
  RETURN to_jsonb(created);
END;
$$;

CREATE OR REPLACE FUNCTION max_task_control(group_id bigint, actor bigint, administrator boolean, identifier bigint,
  operation text, expected_revision integer, source_event bigint, note text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE task durable_tasks;
BEGIN
  PERFORM conversation_id FROM conversations WHERE legacy_group_id=group_id FOR UPDATE;
  SELECT work.* INTO task FROM durable_tasks work JOIN conversations USING(conversation_id)
    WHERE task_id=identifier AND legacy_group_id=group_id FOR UPDATE OF work;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','task not found in this conversation'); END IF;
  IF source_event IS NOT NULL AND NOT EXISTS (SELECT 1 FROM messages
    WHERE canonical_message_id=source_event AND conversation_id=task.conversation_id AND author_principal_id=actor) THEN
    RETURN jsonb_build_object('error','invalid event provenance');
  END IF;
  IF length(trim(note)) NOT BETWEEN 1 AND 40000 THEN RETURN jsonb_build_object('error','note must contain 1..40000 characters'); END IF;
  IF operation<>'steer' AND NOT (administrator OR actor=task.owner_principal_id) THEN
    RETURN jsonb_build_object('error','only the initiator or an administrator can change this task');
  END IF;
  IF operation NOT IN ('steer','replace','cancel') THEN RETURN jsonb_build_object('error','invalid task operation'); END IF;
  IF source_event IS NOT NULL AND EXISTS (SELECT 1 FROM task_events WHERE task_id=identifier AND source_message_id=source_event) THEN
    RETURN jsonb_build_object('queued',true,'task_id',identifier,'revision',task.revision);
  END IF;
  IF operation='replace' AND expected_revision IS DISTINCT FROM task.revision THEN
    RETURN jsonb_build_object('error','revision conflict','revision',task.revision);
  END IF;
  IF operation='steer' AND task.status NOT IN ('queued','running','retrying') AND NOT (administrator OR actor=task.owner_principal_id) THEN
    RETURN jsonb_build_object('error','only the initiator or an administrator can resume completed work');
  END IF;
  IF operation='steer' AND task.status IN ('cancelled','budget_exhausted') THEN
    RETURN jsonb_build_object('error','task is closed; start a new authorized task');
  END IF;
  INSERT INTO task_events(task_id,revision,kind,author_principal_id,source_message_id,body)
    VALUES(identifier,task.revision,operation,actor,source_event,trim(note));
  IF source_event IS NOT NULL THEN
    INSERT INTO conversation_requests(message_id,disposition) VALUES(source_event,CASE WHEN operation='cancel' THEN 'cancelled' ELSE 'delegated' END)
      ON CONFLICT(message_id) DO NOTHING;
  END IF;
  IF operation='replace' THEN
    UPDATE durable_tasks SET revision=revision+1,objective=trim(note),status='queued',result=NULL,next_attempt_at=NULL,last_error=NULL,updated_at=now() WHERE task_id=identifier;
    INSERT INTO task_revisions(task_id,revision,objective,author_principal_id) VALUES(identifier,task.revision+1,trim(note),actor);
  ELSIF operation='cancel' THEN
    UPDATE durable_tasks SET status='cancelled',updated_at=now(),result=jsonb_build_object('status','cancelled','summary',note) WHERE task_id=identifier;
  ELSE
    UPDATE durable_tasks SET status=CASE WHEN status IN ('running','retrying') THEN status ELSE 'queued' END,updated_at=now() WHERE task_id=identifier;
  END IF;
  IF operation IN ('replace','cancel') THEN
    WITH RECURSIVE descendants AS (
      SELECT task_id FROM durable_tasks WHERE parent_task_id=identifier
      UNION ALL SELECT work.task_id FROM durable_tasks work JOIN descendants ON work.parent_task_id=descendants.task_id)
    UPDATE durable_tasks SET status='cancelled',updated_at=now() WHERE task_id IN (SELECT task_id FROM descendants)
      AND status IN ('queued','running','waiting','retrying');
    UPDATE task_attempts SET lease_until=clock_timestamp() WHERE task_id=identifier;
  END IF;
  RETURN jsonb_build_object('queued',true,'task_id',identifier,'revision',task.revision+CASE WHEN operation='replace' THEN 1 ELSE 0 END,
    'note','durably recorded; not yet acted upon');
END;
$$;

CREATE OR REPLACE FUNCTION max_task_claim(worker text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE task durable_tasks; ordinal bigint; admitted bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(872008);
  SELECT work.* INTO task FROM durable_tasks work WHERE (work.status='queued'
    OR work.status='retrying' AND work.next_attempt_at<=clock_timestamp()
    OR work.status='running' AND NOT EXISTS (SELECT 1 FROM task_attempts execution WHERE execution.task_id=work.task_id
      AND execution.attempt=work.attempt AND execution.lease_until>clock_timestamp())
    OR work.status IN ('waiting','retrying') AND work.deadline<=clock_timestamp())
    AND (SELECT count(*) FROM durable_tasks active JOIN task_attempts execution ON execution.task_id=active.task_id AND execution.attempt=active.attempt
      WHERE active.status='running' AND execution.lease_until>clock_timestamp())<40
    AND (SELECT count(*) FROM durable_tasks active JOIN task_attempts execution ON execution.task_id=active.task_id AND execution.attempt=active.attempt
      WHERE active.status='running' AND execution.lease_until>clock_timestamp() AND active.conversation_id=work.conversation_id)<10
    AND (SELECT count(*) FROM durable_tasks active JOIN task_attempts execution ON execution.task_id=active.task_id AND execution.attempt=active.attempt
      WHERE active.status='running' AND execution.lease_until>clock_timestamp() AND active.owner_principal_id=work.owner_principal_id)<10
    AND (work.monitor_fire_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM durable_tasks active JOIN monitor_fires active_fire ON active_fire.fire_id=active.monitor_fire_id
      JOIN monitor_fires candidate_fire ON candidate_fire.fire_id=work.monitor_fire_id
      WHERE active.task_id<>work.task_id AND active.status='running' AND active_fire.monitor_id=candidate_fire.monitor_id
      AND EXISTS(SELECT 1 FROM task_attempts execution WHERE execution.task_id=active.task_id AND execution.attempt=active.attempt AND execution.lease_until>clock_timestamp())))
    AND (work.parent_task_id IS NULL OR EXISTS (SELECT 1 FROM durable_tasks parent WHERE parent.task_id=work.parent_task_id AND parent.status IN ('queued','running','waiting','retrying')))
    ORDER BY (SELECT max(previous.updated_at) FROM durable_tasks previous WHERE previous.owner_principal_id=work.owner_principal_id AND previous.attempt>0) NULLS FIRST,
      work.updated_at,work.task_id LIMIT 1;
  IF NOT FOUND THEN RETURN NULL; END IF;
  PERFORM conversation_id FROM conversations WHERE conversation_id=task.conversation_id FOR UPDATE;
  SELECT * INTO task FROM durable_tasks WHERE task_id=task.task_id FOR UPDATE;
  IF task.status NOT IN ('queued','running','waiting','retrying') THEN RETURN NULL; END IF;
  IF task.deadline<=clock_timestamp() OR task.attempt>=40 THEN
    UPDATE durable_tasks SET status='budget_exhausted',result=jsonb_build_object('status','budget_exhausted','summary','deadline or retry budget exhausted'),updated_at=now() WHERE task_id=task.task_id;
    RETURN NULL;
  END IF;
  IF task.status='running' THEN
    UPDATE durable_tasks SET status='queued' WHERE task_id=task.task_id;
    UPDATE execution_journal SET state='outcome-unknown',finished_at=now(),failure_code='task_lease_expired'
      WHERE state='started' AND turn_id IN (SELECT turn_id FROM task_attempts WHERE task_id=task.task_id);
    UPDATE agent_turns SET status='crashed',finished_at=now(),abort_reason='task execution lease expired'
      WHERE status IN ('starting','running','recovery-pending') AND turn_id IN (SELECT turn_id FROM task_attempts WHERE task_id=task.task_id);
  END IF;
  SELECT COALESCE(max(turn_ordinal),0)+1 INTO ordinal FROM agent_turns WHERE conversation_id=task.conversation_id;
  INSERT INTO agent_turns(conversation_id,turn_ordinal,trigger_canonical_message_id,initiator_principal_id,status)
    VALUES(task.conversation_id,ordinal,task.source_message_id,task.owner_principal_id,'starting') RETURNING turn_id INTO admitted;
  UPDATE durable_tasks SET status='running',attempt=attempt+1,next_attempt_at=NULL,updated_at=now() WHERE task_id=task.task_id;
  INSERT INTO task_attempts(turn_id,task_id,revision,attempt,owner,lease_until)
    VALUES(admitted,task.task_id,task.revision,task.attempt+1,worker,clock_timestamp()+interval '60 seconds');
  RETURN admitted;
END;
$$;

CREATE OR REPLACE FUNCTION max_task_authorize(execution bigint, tool_name text, reserve boolean) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE task durable_tasks; root durable_tasks; attempt task_attempts; turn agent_turns;
BEGIN
  SELECT * INTO turn FROM agent_turns WHERE turn_id=execution;
  IF NOT FOUND OR turn.status NOT IN ('starting','running','recovery-pending') THEN RETURN false; END IF;
  PERFORM conversation_id FROM conversations WHERE conversation_id=turn.conversation_id FOR UPDATE;
  PERFORM turn_id FROM conversation_frontends WHERE turn_id=execution FOR UPDATE;
  IF turn.frontend_managed AND NOT EXISTS (SELECT 1 FROM conversation_frontends WHERE turn_id=execution AND lease_until>clock_timestamp()) THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM task_notifications notice JOIN durable_tasks work USING(task_id)
    WHERE notice.turn_id=execution AND (notice.revision<>work.revision OR notice.attempt<>work.attempt OR notice.body->>'status'<>work.status OR work.status='cancelled' OR notice.superseded_at IS NOT NULL)) THEN RETURN false; END IF;
  SELECT * INTO attempt FROM task_attempts WHERE turn_id=execution;
  IF NOT FOUND THEN RETURN true; END IF;
  SELECT work.* INTO root FROM durable_tasks work WHERE work.task_id=
    (SELECT COALESCE(root_task_id,task_id) FROM durable_tasks WHERE task_id=attempt.task_id) FOR UPDATE;
  SELECT * INTO task FROM durable_tasks WHERE task_id=attempt.task_id FOR UPDATE;
  IF task.status<>'running' OR task.revision<>attempt.revision OR task.attempt<>attempt.attempt
    OR attempt.lease_until<=clock_timestamp() OR root.status NOT IN ('running','queued','waiting','retrying') THEN RETURN false; END IF;
  IF EXISTS (WITH RECURSIVE ancestors AS (
    SELECT parent_task_id FROM durable_tasks WHERE task_id=task.task_id
    UNION ALL SELECT work.parent_task_id FROM durable_tasks work JOIN ancestors ON work.task_id=ancestors.parent_task_id)
    SELECT 1 FROM ancestors JOIN durable_tasks work ON work.task_id=ancestors.parent_task_id WHERE work.status NOT IN ('running','queued','waiting','retrying')) THEN RETURN false; END IF;
  IF tool_name IN ('task_finish','task_progress','request_finish') THEN RETURN true; END IF;
  IF task.deadline<=clock_timestamp() OR root.deadline<=clock_timestamp()
    OR (reserve AND tool_name IS NULL AND (task.rounds_reserved>=task.max_rounds OR root.rounds_reserved>=root.max_rounds))
    OR (reserve AND tool_name IS NOT NULL AND (task.calls_reserved>=task.max_calls OR root.calls_reserved>=root.max_calls)) THEN RETURN false; END IF;
  IF reserve THEN
    UPDATE durable_tasks SET calls_reserved=calls_reserved+CASE WHEN tool_name IS NULL THEN 0 ELSE 1 END,
      rounds_reserved=rounds_reserved+CASE WHEN tool_name IS NULL THEN 1 ELSE 0 END WHERE task_id IN(task.task_id,root.task_id);
  END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION max_task_inbox(execution bigint) RETURNS text LANGUAGE plpgsql AS $$
DECLARE task durable_tasks; through bigint; rendered text;
BEGIN
  SELECT work.* INTO task FROM durable_tasks work JOIN task_attempts attempt USING(task_id)
    WHERE attempt.turn_id=execution AND attempt.revision=work.revision AND attempt.attempt=work.attempt;
  IF NOT FOUND THEN RETURN ''; END IF;
  SELECT max(event_id),string_agg('event#'||event_id||' ['||kind||'] principal#'||COALESCE(author_principal_id::text,'host')||': '||body,E'\n' ORDER BY event_id)
    INTO through,rendered FROM (SELECT * FROM task_events WHERE task_id=task.task_id AND event_id>
      GREATEST(task.consumed_event,(SELECT seen_event FROM task_attempts WHERE turn_id=execution))
      ORDER BY event_id LIMIT 80) events;
  UPDATE task_attempts SET seen_event=GREATEST(seen_event,COALESCE(through,0)) WHERE turn_id=execution;
  RETURN COALESCE(rendered,'');
END;
$$;

CREATE OR REPLACE FUNCTION max_task_report(execution bigint, report_value jsonb) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  IF NOT max_task_authorize(execution,'task_finish',false) THEN RETURN false; END IF;
  IF COALESCE(report_value->>'status','') NOT IN ('succeeded','partial','waiting','failed')
    OR COALESCE(length(trim(report_value->>'summary')),0) NOT BETWEEN 1 AND 40000
    OR octet_length(report_value::text)>80000 THEN RETURN false; END IF;
  IF report_value->>'status'='succeeded' AND EXISTS (SELECT 1 FROM durable_tasks child JOIN task_attempts parent ON child.parent_task_id=parent.task_id
    WHERE parent.turn_id=execution AND child.status IN ('queued','running','waiting','retrying')) THEN RETURN false; END IF;
  UPDATE task_attempts SET report=report_value WHERE turn_id=execution AND (report IS NULL OR report=report_value);
  RETURN FOUND;
END;
$$;

CREATE OR REPLACE FUNCTION max_task_settle() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE task durable_tasks; attempt task_attempts; reported jsonb; pending boolean;
BEGIN
  IF NEW.status NOT IN ('succeeded','silence','failed','aborted','crashed') OR OLD.status=NEW.status THEN RETURN NEW; END IF;
  SELECT * INTO attempt FROM task_attempts WHERE turn_id=NEW.turn_id;
  IF FOUND THEN
    SELECT * INTO task FROM durable_tasks WHERE task_id=attempt.task_id FOR UPDATE;
    IF task.revision=attempt.revision AND task.attempt=attempt.attempt AND task.status='running' AND attempt.lease_until>clock_timestamp() THEN
      reported=COALESCE(attempt.report,jsonb_build_object('status',CASE WHEN task.calls_reserved>=task.max_calls OR task.rounds_reserved>=task.max_rounds OR task.deadline<=clock_timestamp() THEN 'budget_exhausted' ELSE 'failed' END,
        'summary',COALESCE(NEW.abort_reason,'execution ended without task_finish')));
      SELECT EXISTS(SELECT 1 FROM task_events WHERE task_id=task.task_id AND event_id>attempt.seen_event AND kind<>'child_progress') INTO pending;
      IF reported->>'status'='failed' AND (attempt.retryable OR reported->>'failure_kind'='transient')
        AND task.attempt<40 AND task.deadline>now()+interval '5 seconds'
        AND NOT EXISTS(SELECT 1 FROM durable_tasks budget WHERE budget.task_id IN(task.task_id,task.root_task_id)
          AND (budget.calls_reserved>=budget.max_calls OR budget.rounds_reserved>=budget.max_rounds)) THEN
        IF EXISTS (SELECT 1 FROM execution_journal journal JOIN task_attempts history USING(turn_id)
          WHERE history.task_id=task.task_id AND journal.state IN ('started','outcome-unknown')) THEN
          reported=jsonb_set(reported,'{status}','"waiting"');
          reported=reported || jsonb_build_object('unresolved',jsonb_build_array('An external effect is ambiguous; reconcile it before retrying'));
        ELSE
          UPDATE durable_tasks SET status='retrying',result=reported,retry_count=retry_count+1,
            next_attempt_at=now()+make_interval(secs=>LEAST(300,5*power(2,LEAST(retry_count,6)))::integer),
            last_error=reported->>'summary',consumed_event=GREATEST(consumed_event,attempt.seen_event),updated_at=now()
            WHERE task_id=task.task_id;
          INSERT INTO task_events(task_id,revision,kind,body) VALUES(task.task_id,task.revision,'retry_scheduled',left(reported::text,60000));
          RETURN NEW;
        END IF;
      END IF;
      UPDATE durable_tasks SET status=CASE WHEN pending THEN 'queued' ELSE reported->>'status' END,
        result=reported,consumed_event=GREATEST(consumed_event,attempt.seen_event),next_attempt_at=NULL,updated_at=now() WHERE task_id=task.task_id;
    END IF;
  END IF;
  UPDATE task_notifications SET delivered_at=now() WHERE turn_id=NEW.turn_id
    AND superseded_at IS NULL AND NEW.status IN ('succeeded','silence') AND EXISTS (SELECT 1 FROM messages WHERE agent_turn_id=NEW.turn_id);
  UPDATE task_notifications SET next_attempt_at=now()+make_interval(secs=>LEAST(300,5*power(2,LEAST(attempts-1,6)))::integer),
    last_error=COALESCE(NEW.abort_reason,'notification ended without an output receipt')
    WHERE turn_id=NEW.turn_id AND delivered_at IS NULL AND superseded_at IS NULL;
  UPDATE conversation_requests request SET disposition=CASE WHEN work.status='succeeded' THEN 'answered'
    WHEN work.status IN ('partial','waiting') THEN 'waiting' ELSE 'failed' END,
    reason=left(work.result->>'summary',5000),updated_at=now()
    FROM task_notifications notice JOIN durable_tasks work USING(task_id)
    WHERE notice.turn_id=NEW.turn_id AND notice.delivered_at IS NOT NULL
    AND notice.kind='result' AND notice.superseded_at IS NULL AND notice.revision=work.revision AND notice.attempt=work.attempt AND work.monitor_fire_id IS NULL
    AND (request.message_id=work.source_message_id OR EXISTS (SELECT 1 FROM task_events WHERE task_id=work.task_id AND source_message_id=request.message_id))
    AND NOT EXISTS (SELECT 1 FROM durable_tasks other WHERE other.source_message_id=request.message_id AND other.status IN ('queued','running','waiting','retrying'));
  IF NEW.frontend_managed THEN
    UPDATE conversation_requests SET disposition=CASE WHEN disposition='delegated' THEN disposition
      WHEN NEW.status IN ('succeeded','silence') AND EXISTS(SELECT 1 FROM messages WHERE agent_turn_id=NEW.turn_id)
      THEN COALESCE((SELECT disposition FROM request_outcomes WHERE turn_id=NEW.turn_id),'waiting') ELSE 'failed' END,
      reason=COALESCE((SELECT left(reply,5000) FROM request_outcomes WHERE turn_id=NEW.turn_id),NEW.abort_reason,'No explicit request disposition was recorded'),updated_at=now() WHERE turn_id=NEW.turn_id;
    DELETE FROM conversation_frontends WHERE turn_id=NEW.turn_id;
    PERFORM pg_notify('max_dispatch_work','1');
    PERFORM pg_notify('max_task_work','1');
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION max_task_completion() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status NOT IN ('succeeded','partial','waiting','failed','budget_exhausted','cancelled') OR OLD.status=NEW.status THEN RETURN NEW; END IF;
  UPDATE task_notifications SET superseded_at=now() WHERE task_id=NEW.task_id AND kind='progress' AND delivered_at IS NULL;
  IF NEW.status<>'waiting' THEN
    UPDATE durable_tasks SET status='cancelled',updated_at=now() WHERE parent_task_id=NEW.task_id AND status IN ('queued','running','waiting','retrying');
  END IF;
  IF NEW.parent_task_id IS NULL THEN
    IF NEW.status='waiting' AND EXISTS(SELECT 1 FROM durable_tasks WHERE parent_task_id=NEW.task_id AND status IN ('queued','running','waiting','retrying')) THEN RETURN NEW; END IF;
    IF NEW.status='cancelled' AND NEW.monitor_fire_id IS NULL THEN
      UPDATE conversation_requests SET disposition='cancelled',reason='task cancelled',updated_at=now()
        WHERE message_id=NEW.source_message_id AND NOT EXISTS(SELECT 1 FROM durable_tasks WHERE source_message_id=NEW.source_message_id AND status IN ('queued','running','waiting','retrying'));
    END IF;
    IF NEW.monitor_fire_id IS NOT NULL AND EXISTS (SELECT 1 FROM monitor_fires current_fire JOIN monitors definition USING(monitor_id)
      WHERE current_fire.fire_id=NEW.monitor_fire_id AND COALESCE((current_fire.definition_snapshot->>'change_only')::boolean,definition.change_only) AND
      (NEW.status NOT IN ('failed','budget_exhausted') AND jsonb_build_object('status',NEW.status,'observation',COALESCE(NEW.result->'observation',NEW.result))=(
        SELECT jsonb_build_object('status',previous.status,'observation',COALESCE(previous.result->'observation',previous.result)) FROM monitor_fires previous_fire JOIN durable_tasks previous ON previous.task_id=previous_fire.task_id
        WHERE previous_fire.monitor_id=definition.monitor_id AND previous_fire.definition_revision=current_fire.definition_revision
        AND previous.task_id<>NEW.task_id AND previous.status IN ('succeeded','partial','waiting','failed','budget_exhausted')
        ORDER BY previous.updated_at DESC,previous.task_id DESC LIMIT 1)
      OR NEW.status IN ('failed','budget_exhausted') AND EXISTS (
        SELECT 1 FROM monitor_fires previous_fire JOIN durable_tasks previous ON previous.task_id=previous_fire.task_id
        JOIN task_notifications notice ON notice.task_id=previous.task_id
        WHERE previous_fire.monitor_id=definition.monitor_id AND previous_fire.definition_revision=current_fire.definition_revision
        AND notice.body->>'status'=NEW.status AND previous.updated_at>now()-interval '1 hour'))) THEN RETURN NEW; END IF;
    INSERT INTO task_notifications(task_id,revision,attempt,body) VALUES(NEW.task_id,NEW.revision,NEW.attempt,
      COALESCE(NEW.result,jsonb_build_object('status',NEW.status,'summary',NEW.status))) ON CONFLICT DO NOTHING;
  ELSE
    INSERT INTO task_events(task_id,revision,kind,body)
      SELECT task_id,revision,'child_result',left('task#'||NEW.task_id||' revision '||NEW.revision||': '||COALESCE(NEW.result::text,NEW.status),60000)
      FROM durable_tasks WHERE task_id=NEW.parent_task_id AND status IN ('running','queued','waiting','retrying');
    UPDATE durable_tasks SET status='queued',updated_at=now() WHERE task_id=NEW.parent_task_id AND status='waiting';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION max_frontend_claim(execution bigint) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE turn agent_turns;
BEGIN
  SELECT * INTO turn FROM agent_turns WHERE turn_id=execution;
  IF NOT FOUND OR turn.status NOT IN ('starting','running','recovery-pending') THEN RETURN false; END IF;
  PERFORM conversation_id FROM conversations WHERE conversation_id=turn.conversation_id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM conversation_frontends WHERE conversation_id=turn.conversation_id
    AND turn_id<>execution AND lease_until>clock_timestamp()) THEN RETURN false; END IF;
  INSERT INTO conversation_frontends(conversation_id,turn_id,lease_until)
    VALUES(turn.conversation_id,execution,clock_timestamp()+interval '450 seconds')
    ON CONFLICT(conversation_id) DO UPDATE SET turn_id=execution,lease_until=excluded.lease_until;
  UPDATE agent_turns SET frontend_managed=true WHERE turn_id=execution;
  IF turn.trigger_canonical_message_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM task_notifications WHERE turn_id=execution) THEN
    INSERT INTO conversation_requests(message_id,turn_id) VALUES(turn.trigger_canonical_message_id,execution)
      ON CONFLICT(message_id) DO UPDATE SET turn_id=execution WHERE conversation_requests.disposition='pending';
  END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION max_task_output_guard() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE managed boolean;
BEGIN
  IF NEW.agent_turn_id IS NULL THEN RETURN NEW; END IF;
  IF EXISTS (SELECT 1 FROM task_attempts WHERE turn_id=NEW.agent_turn_id) THEN
    RAISE EXCEPTION 'background tasks cannot publish conversation output';
  END IF;
  SELECT frontend_managed INTO managed FROM agent_turns WHERE turn_id=NEW.agent_turn_id;
  IF managed AND NOT max_task_authorize(NEW.agent_turn_id,'task_finish',false) THEN
    RAISE EXCEPTION 'conversation output lost its execution fence';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION max_monitor_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE definition monitors; pending bigint; queued integer;
BEGIN
  SELECT * INTO definition FROM monitors WHERE monitor_id=NEW.monitor_id FOR UPDATE;
  NEW.definition_revision=definition.definition_revision;
  NEW.definition_snapshot=jsonb_build_object('goal',definition.goal_text,'grants',definition.effect_ceiling,
    'required_role',definition.required_role,'profile',definition.task_profile,'change_only',definition.change_only,'overlap',definition.overlap_policy,'queue_limit',definition.queue_limit);
  IF definition.continuation_kind<>'elaborated' THEN RETURN NEW; END IF;
  SELECT count(*),min(fire_id) INTO queued,pending FROM monitor_fires fire LEFT JOIN durable_tasks work ON work.task_id=fire.task_id
    WHERE fire.monitor_id=NEW.monitor_id AND fire.cancelled_at IS NULL AND fire.definition_revision=NEW.definition_revision
      AND (fire.admission_state='pending' OR work.status='queued');
  IF definition.overlap_policy='coalesce' AND queued>=1 THEN
    NEW.disposition='coalesced'; NEW.coalesced_into=pending; NEW.cancelled_at=now();
    IF definition.trigger_kind='time_cron' THEN NEW.cancelled_at=NULL; END IF;
  ELSIF definition.overlap_policy='queue' AND queued>=definition.queue_limit THEN
    NEW.disposition='overflow'; NEW.cancelled_at=now(); NEW.last_error='bounded monitor queue full';
    IF definition.trigger_kind='time_cron' THEN NEW.cancelled_at=NULL; END IF;
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION max_monitor_task_admit(worker text, occurrence bigint, next_fire timestamptz, tool_grants jsonb, seed bigint)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE fire monitor_fires; definition monitors; created durable_tasks;
BEGIN
  PERFORM conversation_id FROM conversations WHERE conversation_id=(SELECT conversation_id FROM monitor_fires WHERE fire_id=occurrence) FOR UPDATE;
  SELECT * INTO fire FROM monitor_fires WHERE fire_id=occurrence FOR UPDATE;
  IF fire.task_id IS NOT NULL THEN RETURN jsonb_build_object('task_id',fire.task_id); END IF;
  IF NOT FOUND OR fire.admission_state<>'pending' OR fire.cancelled_at IS NOT NULL
    OR fire.claim_owner IS DISTINCT FROM worker OR fire.claim_expires_at<=clock_timestamp() THEN
    RETURN jsonb_build_object('error','occurrence claim lost');
  END IF;
  SELECT * INTO definition FROM monitors WHERE monitor_id=fire.monitor_id FOR UPDATE;
  IF fire.disposition IN ('coalesced','overflow') THEN
    UPDATE monitor_fires SET admission_state='dispatched',dispatched_at=now(),claim_owner=NULL,claim_expires_at=NULL WHERE fire_id=occurrence;
    UPDATE monitors SET next_fire_at=next_fire,updated_at=now() WHERE monitor_id=definition.monitor_id AND trigger_kind='time_cron';
    RETURN jsonb_build_object('disposition',fire.disposition,'coalesced_into',fire.coalesced_into);
  END IF;
  IF definition.armed_by_principal_id IS NULL OR definition.arming_turn_id IS NULL
    OR NOT (definition.status='armed' OR definition.status='expired' AND definition.status_reason='max_fire_count')
    OR definition.expires_at<=clock_timestamp()
    OR NOT EXISTS (SELECT 1 FROM messages WHERE canonical_message_id=seed AND conversation_id=fire.conversation_id
      AND author_principal_id=definition.armed_by_principal_id) THEN RETURN jsonb_build_object('error','monitor authority unavailable'); END IF;
  IF EXISTS (SELECT 1 FROM jsonb_each_text(tool_grants) entry WHERE
    COALESCE(fire.definition_snapshot->'grants',definition.effect_ceiling)->'tool_grants'->>entry.key IS DISTINCT FROM entry.value) THEN
    RETURN jsonb_build_object('error','monitor authority widened');
  END IF;
  PERFORM conversation_id FROM conversations WHERE conversation_id=fire.conversation_id FOR UPDATE;
  IF NOT (definition.trigger_kind='time_cron' AND definition.schedule_cron IS NULL) AND
    (SELECT count(*) FROM monitor_fires recent JOIN monitors monitor USING(monitor_id)
      WHERE recent.conversation_id=fire.conversation_id AND monitor.continuation_kind='elaborated'
      AND NOT (monitor.trigger_kind='time_cron' AND monitor.schedule_cron IS NULL)
      AND recent.admission_state='dispatched' AND recent.disposition NOT IN ('coalesced','overflow') AND recent.dispatched_at>now()-interval '1 hour')>=20 THEN
    UPDATE monitor_fires SET claim_owner=NULL,claim_expires_at=NULL WHERE fire_id=occurrence;
    RETURN jsonb_build_object('error','monitor hourly admission budget');
  END IF;
  INSERT INTO durable_tasks(conversation_id,owner_principal_id,source_turn_id,source_message_id,admission_key,
    monitor_fire_id,objective,profile,inputs,grants)
    VALUES(fire.conversation_id,definition.armed_by_principal_id,definition.arming_turn_id,seed,'monitor-fire:'||occurrence,
      occurrence,COALESCE(fire.definition_snapshot->>'goal',definition.goal_text),COALESCE(fire.definition_snapshot->>'profile',definition.task_profile),
      jsonb_build_object('trigger',fire.trigger_evidence,'scheduled_at',fire.scheduled_at,'definition_revision',fire.definition_revision,
        'coalesced_evidence',(SELECT jsonb_agg(jsonb_build_object('fire',fire_id,'evidence',left(trigger_evidence,5000)))
          FROM (SELECT fire_id,trigger_evidence FROM monitor_fires WHERE coalesced_into=occurrence ORDER BY fire_id DESC LIMIT 80) observations)),tool_grants) RETURNING * INTO created;
  INSERT INTO task_revisions(task_id,revision,objective,author_principal_id) VALUES(created.task_id,1,created.objective,created.owner_principal_id);
  UPDATE monitor_fires SET admission_state='dispatched',dispatched_at=now(),task_id=created.task_id,disposition='task',
    claim_owner=NULL,claim_expires_at=NULL,next_attempt_at=NULL,last_error=NULL,parked_at=NULL WHERE fire_id=occurrence;
  IF definition.trigger_kind='time_cron' THEN
    UPDATE monitors SET status=CASE WHEN next_fire IS NULL THEN 'fired' ELSE 'armed' END,next_fire_at=next_fire,
      fire_count=fire_count+CASE WHEN fire.counted_at_admission THEN 0 ELSE 1 END,updated_at=now() WHERE monitor_id=definition.monitor_id;
  END IF;
  RETURN jsonb_build_object('task_id',created.task_id);
END;
$$;

CREATE OR REPLACE FUNCTION max_task_resource(execution bigint, resource_name text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE identifier bigint; owning bigint;
BEGIN
  IF resource_name IS NULL THEN RETURN true; END IF;
  IF NOT max_task_authorize(execution,'task_finish',false) THEN RETURN false; END IF;
  IF NOT EXISTS (SELECT 1 FROM sandboxes sandbox JOIN agent_turns turn USING(conversation_id)
    WHERE turn.turn_id=execution AND sandbox.sandbox_handle=resource_name AND sandbox.status<>'destroyed') THEN RETURN false; END IF;
  SELECT task_id INTO identifier FROM task_attempts WHERE turn_id=execution;
  PERFORM pg_advisory_xact_lock(hashtextextended('task-resource:'||resource_name,0));
  DELETE FROM task_resource_owners owner USING durable_tasks work WHERE owner.task_id=work.task_id
    AND owner.resource=resource_name AND work.status NOT IN ('running','queued','waiting','retrying')
    AND NOT EXISTS (SELECT 1 FROM task_attempts execution JOIN execution_journal journal USING(turn_id)
      WHERE execution.task_id=owner.task_id AND journal.state IN ('started','outcome-unknown')
      AND journal.normalized_input->>'sandbox_id'=resource_name);
  SELECT task_id INTO owning FROM task_resource_owners WHERE resource=resource_name;
  IF owning IS NOT NULL THEN RETURN owning IS NOT DISTINCT FROM identifier; END IF;
  IF identifier IS NOT NULL THEN INSERT INTO task_resource_owners VALUES(resource_name,identifier); END IF;
  RETURN true;
END;
$$;

CREATE OR REPLACE FUNCTION max_monitor_control(group_id bigint, actor bigint, administrator boolean, ordinal bigint,
  operation text, expected_revision integer, objective_text text, overlap text, capacity integer,
  pending_policy text, cancel_tasks boolean)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE definition monitors; active_task bigint;
BEGIN
  PERFORM conversation_id FROM conversations WHERE legacy_group_id=group_id FOR UPDATE;
  SELECT monitor.* INTO definition FROM monitors monitor JOIN conversations USING(conversation_id)
    WHERE legacy_group_id=group_id AND monitor_ordinal=ordinal FOR UPDATE OF monitor;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','monitor not found'); END IF;
  IF NOT COALESCE(administrator OR definition.armed_by_principal_id=actor,false) THEN RETURN jsonb_build_object('error','monitor owner or administrator required'); END IF;
  IF operation='configure' THEN
    IF expected_revision IS DISTINCT FROM definition.definition_revision THEN RETURN jsonb_build_object('error','revision conflict'); END IF;
    IF length(trim(objective_text)) NOT BETWEEN 1 AND 40000 OR overlap NOT IN ('coalesce','queue')
      OR capacity NOT BETWEEN 1 AND 160 OR pending_policy NOT IN ('retain','cancel') THEN RETURN jsonb_build_object('error','invalid monitor definition'); END IF;
    UPDATE monitors SET goal_text=trim(objective_text),definition_revision=definition_revision+1,overlap_policy=overlap,
      queue_limit=capacity,updated_at=now() WHERE monitor_id=definition.monitor_id;
  ELSIF operation='cancel' THEN
    UPDATE monitors SET status='cancelled',cancelled_at=now(),next_fire_at=NULL,updated_at=now() WHERE monitor_id=definition.monitor_id;
  ELSE RETURN jsonb_build_object('error','invalid operation'); END IF;
  IF operation='cancel' OR pending_policy='cancel' THEN
    UPDATE monitor_fires SET cancelled_at=now(),disposition='cancelled',claim_owner=NULL,claim_expires_at=NULL
      WHERE monitor_id=definition.monitor_id AND admission_state='pending' AND cancelled_at IS NULL;
  END IF;
  IF cancel_tasks THEN
    FOR active_task IN SELECT work.task_id FROM durable_tasks work JOIN monitor_fires fire ON fire.fire_id=work.monitor_fire_id
      WHERE fire.monitor_id=definition.monitor_id AND work.status IN ('queued','running','waiting','retrying') LOOP
      PERFORM max_task_control(group_id,actor,true,active_task,'cancel',NULL,NULL,'monitor controller explicitly cancelled admitted work');
    END LOOP;
  END IF;
  RETURN jsonb_build_object('ok',true,'revision',definition.definition_revision+CASE WHEN operation='configure' THEN 1 ELSE 0 END,
    'admitted_tasks_cancelled',cancel_tasks,'pending_policy',pending_policy);
END;
$$;

CREATE OR REPLACE FUNCTION max_task_steer_child(execution bigint, identifier bigint, note text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE actor bigint; group_id bigint;
BEGIN
  IF NOT max_task_authorize(execution,'task_finish',false) OR NOT EXISTS (
    SELECT 1 FROM durable_tasks child JOIN task_attempts parent ON child.parent_task_id=parent.task_id
    WHERE parent.turn_id=execution AND child.task_id=identifier) THEN
    RETURN jsonb_build_object('error','only a current parent may steer its direct child');
  END IF;
  SELECT initiator_principal_id,legacy_group_id INTO actor,group_id FROM agent_turns JOIN conversations USING(conversation_id) WHERE turn_id=execution;
  RETURN max_task_control(group_id,actor,false,identifier,'steer',NULL,NULL,note);
END;
$$;

CREATE FUNCTION max_task_progress(execution bigint, progress_value jsonb) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE task durable_tasks; previous task_progress; pending bigint; wake_at timestamptz;
BEGIN
  IF NOT max_task_authorize(execution,'task_progress',false) THEN RETURN false; END IF;
  SELECT work.* INTO task FROM durable_tasks work JOIN task_attempts attempt USING(task_id)
    WHERE attempt.turn_id=execution AND work.status='running';
  IF NOT FOUND OR COALESCE(length(trim(progress_value->>'summary')),0) NOT BETWEEN 1 AND 40000
    OR octet_length(progress_value::text)>80000 THEN RETURN false; END IF;
  progress_value=progress_value || jsonb_build_object('status','running');
  SELECT * INTO previous FROM task_progress WHERE task_id=task.task_id;
  IF previous.revision=task.revision AND previous.attempt=task.attempt AND previous.body=progress_value THEN RETURN true; END IF;
  INSERT INTO task_progress(task_id,revision,attempt,body) VALUES(task.task_id,task.revision,task.attempt,progress_value)
    ON CONFLICT(task_id) DO UPDATE SET revision=excluded.revision,attempt=excluded.attempt,
      version=task_progress.version+1,body=excluded.body,updated_at=now();
  IF task.parent_task_id IS NOT NULL THEN
    INSERT INTO task_events(task_id,revision,kind,body)
      SELECT task_id,revision,'child_progress',left('task#'||task.task_id||': '||progress_value::text,60000)
      FROM durable_tasks WHERE task_id=task.parent_task_id AND status IN ('queued','running','waiting','retrying');
  ELSE
    SELECT notification_id INTO pending FROM task_notifications WHERE task_id=task.task_id AND kind='progress'
      AND turn_id IS NULL AND delivered_at IS NULL AND superseded_at IS NULL ORDER BY notification_id DESC LIMIT 1;
    IF FOUND THEN
      UPDATE task_notifications SET body=progress_value,revision=task.revision,attempt=task.attempt WHERE notification_id=pending;
    ELSE
      SELECT GREATEST(now(),max(created_at)+interval '30 seconds') INTO wake_at
        FROM task_notifications WHERE task_id=task.task_id AND kind='progress';
      INSERT INTO task_notifications(task_id,revision,attempt,body,kind,next_attempt_at)
        VALUES(task.task_id,task.revision,task.attempt,progress_value,'progress',wake_at);
    END IF;
  END IF;
  RETURN true;
END;
$$;

CREATE FUNCTION max_request_finish(execution bigint, decision text, response_text text) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  IF decision NOT IN ('answered','waiting','declined') OR length(trim(response_text)) NOT BETWEEN 1 AND 40000
    OR NOT max_task_authorize(execution,'request_finish',false)
    OR NOT EXISTS(SELECT 1 FROM conversation_frontends WHERE turn_id=execution AND lease_until>clock_timestamp())
    OR EXISTS(SELECT 1 FROM task_notifications WHERE turn_id=execution) THEN RETURN false; END IF;
  INSERT INTO request_outcomes(turn_id,disposition,reply) VALUES(execution,decision,trim(response_text))
    ON CONFLICT(turn_id) DO NOTHING;
  RETURN EXISTS(SELECT 1 FROM request_outcomes WHERE turn_id=execution AND disposition=decision AND reply=trim(response_text));
END;
$$;

CREATE FUNCTION max_task_failure(execution bigint, detail text, can_retry boolean) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  IF NOT max_task_authorize(execution,'task_finish',false) THEN RETURN false; END IF;
  UPDATE task_attempts SET retryable=can_retry,
    report=jsonb_build_object('status','failed','summary',left(detail,40000),
      'failure_kind',CASE WHEN can_retry THEN 'transient' ELSE 'permanent' END)
    WHERE turn_id=execution AND report IS NULL;
  RETURN FOUND;
END;
$$;

CREATE FUNCTION max_monitor_configure(group_id bigint, actor bigint, administrator boolean, ordinal bigint,
  expected_revision integer, objective_text text, overlap text, capacity integer, pending_policy text,
  capability text, changed_only boolean) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE outcome jsonb;
BEGIN
  IF capability NOT IN ('research','browser','sandbox') THEN RETURN jsonb_build_object('error','invalid task profile'); END IF;
  outcome=max_monitor_control(group_id,actor,administrator,ordinal,'configure',expected_revision,
    objective_text,overlap,capacity,pending_policy,false);
  IF outcome ? 'error' THEN RETURN outcome; END IF;
  UPDATE monitors definition SET task_profile=capability,change_only=changed_only
    FROM conversations WHERE conversations.conversation_id=definition.conversation_id
    AND legacy_group_id=group_id AND monitor_ordinal=ordinal;
  RETURN outcome || jsonb_build_object('profile',capability,'change_only',changed_only);
END;
$$;
