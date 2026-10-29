//! What Max does in a QQ group as one of its admins: mute. A tool calls
//! it straight away, not through the sender: a mute leaves no row on the
//! timeline, so there is nothing to keep in order with what Max says, and
//! doing one twice does no harm.

use qqbot::api::{Mute, Muted};

use super::send::Answer;

/// QQ's client in service; a recorder in tests.
pub trait Admin: Send + Sync + 'static {
    /// Who is muted in a group now.
    fn muted<'a>(&'a self, group: &'a str) -> Answer<'a, Vec<Muted>>;
    fn mute<'a>(&'a self, group: &'a str, mute: &'a Mute<'a>) -> Answer<'a, ()>;
}

impl Admin for qqbot::Client {
    fn muted<'a>(&'a self, group: &'a str) -> Answer<'a, Vec<Muted>> {
        Box::pin(qqbot::Client::muted(self, group))
    }

    fn mute<'a>(&'a self, group: &'a str, mute: &'a Mute<'a>) -> Answer<'a, ()> {
        Box::pin(qqbot::Client::mute(self, group, mute))
    }
}
