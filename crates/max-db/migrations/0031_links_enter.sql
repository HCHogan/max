-- Max in one conversation no longer asks Max in another. A link lets it
-- enter the other's VM, where what it runs is the other's: an edge runs
-- from the conversation whose Max enters to the one whose VM it is. See
-- "Entering another conversation's VM" in docs/design/vm.md.
drop table questions;

alter table links rename column asker_id to from_id;
alter table links rename column asked_id to to_id;
alter table links rename constraint links_asker_id_fkey to links_from_id_fkey;
alter table links rename constraint links_asked_id_fkey to links_to_id_fkey;
alter index links_asked_id_idx rename to links_to_id_idx;
alter table links rename constraint links_asker_id_not_null to links_from_id_not_null;
alter table links rename constraint links_asked_id_not_null to links_to_id_not_null;
