CREATE TABLE browser_workspaces (
  task_id bigint PRIMARY KEY REFERENCES durable_tasks ON DELETE CASCADE,
  revision integer NOT NULL,
  generation bigint NOT NULL DEFAULT 1,
  epoch bigint NOT NULL DEFAULT 0,
  owner_turn_id bigint REFERENCES agent_turns ON DELETE SET NULL,
  runtime_id text,
  state text NOT NULL DEFAULT 'cold' CHECK (state IN ('cold','hot','busy','uncertain','revoked')),
  checkpoint text,
  checkpoint_at timestamptz,
  last_used_at timestamptz NOT NULL DEFAULT now(),
  profile_id bigint,
  profile_version bigint,
  UNIQUE(task_id,generation)
);

CREATE TABLE browser_profiles (
  profile_id bigserial PRIMARY KEY,
  conversation_id bigint NOT NULL REFERENCES conversations ON DELETE CASCADE,
  principal_id bigint NOT NULL REFERENCES principals ON DELETE CASCADE,
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 80),
  origin text NOT NULL,
  version bigint NOT NULL DEFAULT 1,
  checkpoint text,
  revoked boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(conversation_id,principal_id,name)
);

ALTER TABLE browser_workspaces ADD FOREIGN KEY(profile_id) REFERENCES browser_profiles;

CREATE TABLE browser_monitor_profiles (
  monitor_id bigint PRIMARY KEY REFERENCES monitors ON DELETE CASCADE,
  profile_id bigint NOT NULL REFERENCES browser_profiles,
  profile_version bigint NOT NULL
);

CREATE TABLE browser_command_events (
  event_id bigserial PRIMARY KEY,
  conversation_id bigint NOT NULL REFERENCES conversations ON DELETE CASCADE,
  principal_id bigint NOT NULL REFERENCES principals ON DELETE CASCADE,
  operation text NOT NULL,
  task_id bigint REFERENCES durable_tasks ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE browser_command_receipts (
  message_id bigint PRIMARY KEY REFERENCES messages(canonical_message_id) ON DELETE CASCADE,
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION max_browser_fire_profile() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.definition_snapshot=NEW.definition_snapshot || COALESCE((SELECT jsonb_build_object('browser_profile_id',profile_id,'browser_profile_version',profile_version)
    FROM browser_monitor_profiles WHERE monitor_id=NEW.monitor_id),'{}'::jsonb);
  RETURN NEW;
END;
$$;
CREATE TRIGGER zz_browser_fire_profile BEFORE INSERT ON monitor_fires FOR EACH ROW EXECUTE FUNCTION max_browser_fire_profile();

CREATE FUNCTION max_browser_acquire(execution bigint, runtime text) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE attempt task_attempts; work durable_tasks; workspace browser_workspaces;
BEGIN
  IF NOT max_task_authorize(execution,'browser_navigate',false) THEN
    RETURN jsonb_build_object('error','browser execution was fenced');
  END IF;
  SELECT * INTO attempt FROM task_attempts WHERE turn_id=execution;
  IF NOT FOUND THEN RETURN jsonb_build_object('frontend',true); END IF;
  SELECT * INTO work FROM durable_tasks WHERE task_id=attempt.task_id;
  INSERT INTO browser_workspaces(task_id,revision,profile_id,profile_version)
    VALUES(work.task_id,work.revision,
      (SELECT (definition_snapshot->>'browser_profile_id')::bigint FROM monitor_fires WHERE fire_id=work.monitor_fire_id),
      (SELECT (definition_snapshot->>'browser_profile_version')::bigint FROM monitor_fires WHERE fire_id=work.monitor_fire_id)) ON CONFLICT DO NOTHING;
  SELECT * INTO workspace FROM browser_workspaces WHERE task_id=work.task_id FOR UPDATE;
  IF workspace.state='revoked' THEN RETURN jsonb_build_object('error','browser workspace revoked; owner must reset it'); END IF;
  IF workspace.state IN ('busy','uncertain') THEN
    UPDATE browser_workspaces SET state='uncertain' WHERE task_id=work.task_id;
    RETURN jsonb_build_object('error','browser outcome unknown; inspect external effects and use !browser reset task#N; never replay the previous action');
  END IF;
  IF workspace.profile_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM browser_profiles WHERE profile_id=workspace.profile_id AND version=workspace.profile_version AND NOT revoked
      AND principal_id=work.owner_principal_id AND conversation_id=work.conversation_id
  ) THEN
    UPDATE browser_workspaces SET state='revoked',checkpoint=NULL WHERE task_id=work.task_id;
    RETURN jsonb_build_object('error','browser authentication profile revoked');
  END IF;
  IF workspace.revision<>work.revision THEN
    UPDATE browser_workspaces SET revision=work.revision,generation=generation+1,state='cold',checkpoint=NULL,
      checkpoint_at=NULL,owner_turn_id=NULL,runtime_id=NULL,profile_id=NULL,profile_version=NULL WHERE task_id=work.task_id;
  ELSIF workspace.runtime_id IS DISTINCT FROM runtime AND workspace.state='hot' THEN
    UPDATE browser_workspaces SET generation=generation+1,state='cold',owner_turn_id=NULL,runtime_id=NULL WHERE task_id=work.task_id;
  END IF;
  UPDATE browser_workspaces SET epoch=epoch+1,owner_turn_id=execution,runtime_id=runtime,last_used_at=clock_timestamp()
    WHERE task_id=work.task_id RETURNING * INTO workspace;
  RETURN to_jsonb(workspace) || jsonb_build_object('lease_until',attempt.lease_until,
    'profile_checkpoint',(SELECT checkpoint FROM browser_profiles WHERE profile_id=workspace.profile_id));
END;
$$;

CREATE FUNCTION max_browser_begin(execution bigint, expected_epoch bigint) RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  IF NOT max_task_authorize(execution,'browser_navigate',false) THEN RETURN false; END IF;
  UPDATE browser_workspaces SET state='busy',last_used_at=clock_timestamp()
    WHERE owner_turn_id=execution AND epoch=expected_epoch AND state IN ('hot','cold');
  RETURN FOUND;
END;
$$;

CREATE FUNCTION max_browser_finish(execution bigint, expected_epoch bigint, saved text, healthy boolean) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE authorized boolean;
BEGIN
  authorized := max_task_authorize(execution,'browser_navigate',false);
  UPDATE browser_workspaces SET state=CASE WHEN healthy AND authorized THEN 'hot' ELSE 'uncertain' END,
    checkpoint=CASE WHEN healthy AND authorized THEN COALESCE(saved,checkpoint) ELSE checkpoint END,
    checkpoint_at=CASE WHEN healthy AND authorized AND saved IS NOT NULL THEN clock_timestamp() ELSE checkpoint_at END,
    last_used_at=clock_timestamp()
    WHERE owner_turn_id=execution AND epoch=expected_epoch AND state='busy';
  RETURN FOUND AND authorized;
END;
$$;

CREATE FUNCTION max_browser_task_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IN ('cancelled','budget_exhausted') OR NEW.revision<>OLD.revision THEN
    UPDATE browser_workspaces SET state='revoked',epoch=epoch+1,checkpoint=NULL,checkpoint_at=NULL
      WHERE task_id=NEW.task_id;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER browser_task_changed AFTER UPDATE ON durable_tasks FOR EACH ROW EXECUTE FUNCTION max_browser_task_changed();

CREATE FUNCTION max_browser_profile_changed() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.version<>OLD.version OR NEW.revoked THEN
    UPDATE browser_workspaces SET state='revoked',epoch=epoch+1,checkpoint=NULL,checkpoint_at=NULL
      WHERE profile_id=NEW.profile_id;
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER browser_profile_changed AFTER UPDATE ON browser_profiles FOR EACH ROW EXECUTE FUNCTION max_browser_profile_changed();
