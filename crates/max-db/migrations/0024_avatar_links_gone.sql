-- Linking accounts to old QQ numbers by their avatars is gone, and so is
-- what it did: each account it linked is its own person again, the rows
-- that mention one say so, and its tables are dropped. See "按头像接上"
-- in docs/rust-rewrite.md.

-- The accounts it linked, and the old number's principal each was merged
-- into, where that is still so: a merge the owner changed by hand is the
-- owner's.
create temporary table unlinked on commit drop as
select i.id as identity_id, p.id as principal_id, p.merged_into as old_principal_id
from avatar_checks c
join identities i on i.id = c.identity_id
join principals p on p.id = i.principal_id
join identities n on n.id = c.number_id
join principals np on np.id = n.principal_id
where c.outcome = 'linked' and p.merged_into = coalesce(np.merged_into, np.id);

update principals p set merged_into = null
from unlinked u
where p.id = u.principal_id;

-- A row's text is rendered as it is committed, so one that mentions an
-- account after it was linked names the old number's person. Only rows
-- that mention the account itself are changed: the old number's own rows
-- still name that person. No two accounts in a group were linked to one
-- number, so in a row each old handle is one account's.
--
-- The rows' mentions are read once: joined to the accounts directly,
-- the ledger was scanned once for each account: 18 s on tank, against
-- 0.1 s this way.
create temporary table renamed on commit drop as
with mentioned as materialized (
    select m.id, m.text, (n.node -> 'target' ->> 'identity')::bigint as identity_id
    from messages m
    cross join lateral jsonb_array_elements(m.nodes) as n(node)
    where strpos(m.text, '[mention#') > 0 and n.node ->> 'type' = 'mention'
)
select distinct x.id as message_id, u.old_principal_id, u.principal_id
from mentioned x
join unlinked u on u.identity_id = x.identity_id
where strpos(x.text, format('[mention#%s]', u.old_principal_id)) > 0;

-- One handle at a time, as a row may mention two of them.
do $$
declare
    r record;
begin
    for r in select * from renamed loop
        update messages
        set text = replace(
            text,
            format('[mention#%s]', r.old_principal_id),
            format('[mention#%s]', r.principal_id)
        )
        where id = r.message_id;
    end loop;
end
$$;

drop table avatar_checks;
drop table legacy_avatars;
