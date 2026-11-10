//! What Max asks QQ's client of a group straight away, not through the
//! sender: what it is called; and, as one of its admins, who is muted, and
//! to mute. A mute leaves no row on the timeline, so there is nothing to
//! keep in order with what Max says, and doing one twice does no harm.

use qqbot::api::{GroupInfo, Mute, Muted};

use super::send::Answer;

/// QQ's client in service; a recorder in tests.
pub trait Groups: Send + Sync + 'static {
    /// Who is muted in a group now.
    fn muted<'a>(&'a self, group: &'a str) -> Answer<'a, Vec<Muted>>;
    fn mute<'a>(&'a self, group: &'a str, mute: &'a Mute<'a>) -> Answer<'a, ()>;
    /// A group's name, and what else QQ says of it.
    fn info<'a>(&'a self, group: &'a str) -> Answer<'a, GroupInfo>;
}

impl Groups for qqbot::Client {
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
