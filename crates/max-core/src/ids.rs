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

/// What runs or waits in a conversation's background, as Max is shown it:
/// a background agent, `agent#3`; a background command of `shell`'s,
/// `shell#4`; a question between Max here and Max in another
/// conversation, `ask#5`, whichever asked. Each kind is numbered on its
/// own, within the conversation while max runs, so the name says what it
/// is and what may be done with it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(into = "String", try_from = "String")]
pub enum Handle {
    Agent(u32),
    Shell(u32),
    Ask(u32),
}

impl Handle {
    pub fn number(self) -> u32 {
        match self {
            Handle::Agent(number) | Handle::Shell(number) | Handle::Ask(number) => number,
        }
    }
}

impl fmt::Display for Handle {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let kind = match self {
            Handle::Agent(_) => "agent",
            Handle::Shell(_) => "shell",
            Handle::Ask(_) => "ask",
        };
        write!(f, "{kind}#{}", self.number())
    }
}

/// Text that isn't a handle.
#[derive(Debug, thiserror::Error)]
#[error("{0} isn't a handle: write agent#3, shell#4 or ask#5")]
pub struct NotAHandle(String);

impl std::str::FromStr for Handle {
    type Err = NotAHandle;

    fn from_str(text: &str) -> Result<Self, Self::Err> {
        let not = || NotAHandle(text.to_owned());
        let (kind, number) = text.trim().split_once('#').ok_or_else(not)?;
        let number = number.parse().map_err(|_| not())?;
        match kind {
            "agent" => Ok(Handle::Agent(number)),
            "shell" => Ok(Handle::Shell(number)),
            "ask" => Ok(Handle::Ask(number)),
            _ => Err(not()),
        }
    }
}

impl From<Handle> for String {
    fn from(handle: Handle) -> Self {
        handle.to_string()
    }
}

impl TryFrom<String> for Handle {
    type Error = NotAHandle;

    fn try_from(text: String) -> Result<Self, Self::Error> {
        text.parse()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_handle_reads_as_it_is_written() {
        for handle in [Handle::Agent(3), Handle::Shell(4), Handle::Ask(5)] {
            assert_eq!(handle.to_string().parse::<Handle>().unwrap(), handle);
        }
        assert_eq!(" shell#12 ".parse::<Handle>().unwrap(), Handle::Shell(12));
        assert_eq!(
            serde_json::to_value(Handle::Agent(3)).unwrap(),
            serde_json::json!("agent#3")
        );
        for text in ["3", "job#3", "agent#", "agent#-1", "agent#三", "agent 3"] {
            let error = text.parse::<Handle>().unwrap_err();
            assert_eq!(
                error.to_string(),
                format!("{text} isn't a handle: write agent#3, shell#4 or ask#5")
            );
        }
    }
}
