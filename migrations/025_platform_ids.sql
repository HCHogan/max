-- Foreign-platform id mapping (0.4 platform abstraction): WeChat /
-- Telegram / … identify users, channels and messages with strings,
-- while max's whole pipeline speaks bigint.  Each native id gets a
-- synthetic bigint allocated below -10^12 (see
-- Max.Platform.foreignIdBase); the rest of the system never knows the
-- difference, and outbound routing is a pure range check.
CREATE SEQUENCE platform_id_seq;

CREATE TABLE platform_ids (
    platform  text   NOT NULL,           -- 'wechatpad', 'telegram', …
    kind      text   NOT NULL CHECK (kind IN ('user', 'channel', 'message')),
    native_id text   NOT NULL,           -- wxid_…, xxx@chatroom, platform msg id
    mapped_id bigint PRIMARY KEY DEFAULT (-1000000000000 - nextval('platform_id_seq')),
    first_seen_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (platform, kind, native_id)
);
