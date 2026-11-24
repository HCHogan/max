//! WeChat's adapter, through wxdesk: the desktop client in a VM, which
//! wxdesk reads and drives and serves over TCP. See docs/design/wechat.md.

pub mod inbound;

use max_db::platform::ConversationKind;

const GROUP: &str = "group:";
const USER: &str = "user:";

/// A chat as its endpoint's native id has it: `group:<the group's name>`
/// or `user:<the friend's name>`, as the client's session list shows them.
#[must_use]
pub fn native_id(kind: ConversationKind, title: &str) -> String {
    match kind {
        ConversationKind::Group => format!("{GROUP}{title}"),
        ConversationKind::Direct => format!("{USER}{title}"),
    }
}

/// The chat's title in the client, which wxdesk knows it by.
#[must_use]
pub fn title(native_id: &str) -> Option<&str> {
    native_id
        .strip_prefix(GROUP)
        .or_else(|| native_id.strip_prefix(USER))
}

/// The group a native id names, if it names one.
#[must_use]
pub fn group(native_id: &str) -> Option<&str> {
    native_id.strip_prefix(GROUP)
}
