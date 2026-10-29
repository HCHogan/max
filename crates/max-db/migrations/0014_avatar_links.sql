-- Old QQ numbers' avatars, shrunk to 16×16 grey: what a QQ account's
-- avatar is compared with to find its old number. See "按头像接上" in
-- docs/rust-rewrite.md.
create table legacy_avatars (
    identity_id bigint primary key references identities,
    print bytea not null check (length(print) = 256),
    fetched_at timestamptz not null
);

-- What came of comparing a QQ account's avatar with the old numbers', once
-- per account: linked to the number, or why not.
create table avatar_checks (
    identity_id bigint primary key references identities,
    outcome text not null
        check (outcome in ('linked', 'default', 'none', 'ambiguous', 'taken', 'barred')),
    number_id bigint references identities,
    checked_at timestamptz not null,
    check ((outcome in ('linked', 'taken', 'barred')) = (number_id is not null))
);
