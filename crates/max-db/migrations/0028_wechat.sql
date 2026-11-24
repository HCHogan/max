-- WeChat, through its desktop client: see docs/design/wechat.md.
alter table identities
    drop constraint identities_platform_check,
    add constraint identities_platform_check
        check (platform in ('qq', 'qq_legacy', 'matrix', 'wechat'));

alter table endpoints
    drop constraint endpoints_platform_check,
    add constraint endpoints_platform_check
        check (platform in ('qq', 'qq_legacy', 'matrix', 'wechat'));
