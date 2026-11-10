-- Which conversation's Max may ask which other's: `/link` makes an edge,
-- from the asker to the asked and not back, and `/unlink` removes it.
-- See "Asking another conversation" in docs/rust-rewrite.md.
create table links (
    asker_id bigint not null references conversations,
    asked_id bigint not null references conversations,
    made_at timestamptz not null,
    primary key (asker_id, asked_id),
    check (asker_id <> asked_id)
);

create index on links (asked_id);
