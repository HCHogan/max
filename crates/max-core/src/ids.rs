//! Typed ids, so that a message id can't be passed where a principal is
//! expected. Database ids are `i64`, matching Postgres `bigint`.

use std::fmt;

use serde::{Deserialize, Serialize};

macro_rules! ids {
    ($($(#[$doc:meta])* $name:ident($inner:ty);)*) => {$(
        $(#[$doc])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name($inner);

        impl $name {
            /// The id a row has in the database.
            #[must_use]
            pub const fn new(id: $inner) -> Self {
                Self(id)
            }

            /// As the database has it.
            #[must_use]
            pub const fn get(self) -> $inner {
                self.0
            }
        }

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
    /// A conversation: one timeline, whichever chats it is in.
    ConversationId(i64);
    /// Where a conversation lives on one platform.
    EndpointId(i64);
    /// A person. The model addresses people, never platform accounts.
    PrincipalId(i64);
    /// A platform account. The ledger stores these; rendering maps them to
    /// principals.
    IdentityId(i64);
    /// A turn: one run of the core, from its trigger to its outcome.
    TurnId(i64);
}

/// The id a provider gave a tool call; opaque to us.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct CallId(String);

impl CallId {
    /// Of the id as the provider gave it.
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    /// As the provider gave it.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for CallId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}
