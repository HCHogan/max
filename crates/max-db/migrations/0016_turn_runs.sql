-- A turn's run is kept with its outcome, in the one row written as it
-- ends; a turn lost in a crash has none. turn_snapshots was that, one to
-- one with the outcomes and written in the same transaction.

alter table turn_outcomes add column run jsonb;
update turn_outcomes o set run = s.run from turn_snapshots s where s.turn_id = o.turn_id;
drop table turn_snapshots;
