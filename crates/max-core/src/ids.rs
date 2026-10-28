//! Typed ids, so that a message id can't be passed where a principal is
//! expected. Database ids are `i64`, matching Postgres `bigint`.

use std::fmt;

use serde::{Deserialize, Serialize};

macro_rules! ids {
    ($($(#[$doc:meta])* $name:ident($inner:ty);)*) => {$(
        $(#[$doc])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub $inner);

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                self.0.fmt(f)
            }
        }
    )*};
}

ids! {
    /// A row in the ledger. Within a conversation, id order is the order the
    /// conversation actor committed them: the timeline.
    MessageId(i64);
    ConversationId(i64);
    /// Where a conversation lives on one platform.
    EndpointId(i64);
    /// A person. The model addresses people, never platform accounts.
    PrincipalId(i64);
    /// A platform account. The ledger stores these; rendering maps them to
    /// principals.
    IdentityId(i64);
    TurnId(i64);
    /// A summary the historian wrote; the model sees `summary#id`.
    SummaryId(i64);
}

/// The id a provider gave a tool call; opaque to us.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CallId(pub String);

impl fmt::Display for CallId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}
