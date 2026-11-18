//! The QQ official bot: its gateway in, its REST API out. See "The
//! official QQ bot" in docs/rust-rewrite.md.

pub mod groups;
pub mod inbound;
pub mod listen;
pub mod send;

use qqbot::Chat;

const GROUP: &str = "group:";
const C2C: &str = "c2c:";

/// A chat as its endpoint's native id has it: `group:<group_openid>` or
/// `c2c:<user_openid>`. A group of the QQ before this one is named the
/// same way, by its number.
pub fn native_id(chat: Chat<'_>) -> String {
    match chat {
        Chat::Group(group) => format!("{GROUP}{group}"),
        Chat::User(user) => format!("{C2C}{user}"),
    }
}

/// The chat a native id names, if it is one of QQ's.
pub fn chat(native_id: &str) -> Option<Chat<'_>> {
    match native_id.strip_prefix(GROUP) {
        Some(group) => Some(Chat::Group(group)),
        None => native_id.strip_prefix(C2C).map(Chat::User),
    }
}

/// The group a native id names, if it names one.
pub fn group(native_id: &str) -> Option<&str> {
    match chat(native_id)? {
        Chat::Group(group) => Some(group),
        Chat::User(_) => None,
    }
}
