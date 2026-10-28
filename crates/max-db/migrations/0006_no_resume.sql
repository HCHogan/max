-- A restart no longer suspends the turn in flight to resume it: the turn
-- gets a grace period and is interrupted after it. So a turn has one
-- attempt and one snapshot, written as it ends, and nothing expires. A core
-- over its limits fails one way, context_exhausted. See "重启" in
-- docs/rust-rewrite.md.

drop table turn_resumes;

alter table turn_snapshots drop constraint turn_snapshots_pkey;
alter table turn_snapshots drop column attempt, drop column upto_id;
alter table turn_snapshots add primary key (turn_id);

alter table turn_outcomes drop constraint turn_outcomes_outcome_check;
alter table turn_outcomes add constraint turn_outcomes_outcome_check
    check (outcome in ('answered', 'silent', 'interrupted', 'failed', 'lost'));
alter table turn_outcomes drop constraint turn_outcomes_failure_check;
alter table turn_outcomes add constraint turn_outcomes_failure_check
    check (failure in ('model', 'context_exhausted'));
