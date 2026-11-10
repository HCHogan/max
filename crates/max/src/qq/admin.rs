//! What Max asks QQ's client for straight away, not through the sender.
//! As one of a group's admins, to mute: a mute leaves no row on the
//! timeline, so there is nothing to keep in order with what Max says, and
//! doing one twice does no harm. And what a group is called, which needs
//! no admin.

use qqbot::api::{GroupInfo, Mute, Muted};

use super::send::Answer;

/// QQ's client in service; a recorder in tests.
pub trait Admin: Send + Sync + 'static {
    /// Who is muted in a group now.
    fn muted<'a>(&'a self, group: &'a str) -> Answer<'a, Vec<Muted>>;
    fn mute<'a>(&'a self, group: &'a str, mute: &'a Mute<'a>) -> Answer<'a, ()>;
    /// A group's name, and what else QQ says of it.
    fn info<'a>(&'a self, group: &'a str) -> Answer<'a, GroupInfo>;
}

impl Admin for qqbot::Client {
    fn muted<'a>(&'a self, group: &'a str) -> Answer<'a, Vec<Muted>> {
        Box::pin(qqbot::Client::muted(self, group))
    }

    fn mute<'a>(&'a self, group: &'a str, mute: &'a Mute<'a>) -> Answer<'a, ()> {
        Box::pin(qqbot::Client::mute(self, group, mute))
    }

    fn info<'a>(&'a self, group: &'a str) -> Answer<'a, GroupInfo> {
        Box::pin(qqbot::Client::info(self, group))
    }
}
