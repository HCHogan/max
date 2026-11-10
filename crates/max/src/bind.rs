//! `/bind` codes. An owner asks for one in a private chat, for an old
//! conversation or a new one, and says it in a QQ group to bind the group
//! to it.

use max_core::ids::{ConversationId, PrincipalId};

use crate::code::Codes;

/// What a code binds a group to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pending {
    /// None for a new conversation.
    pub conversation: Option<ConversationId>,
    /// Who asked: their account in the group is merged into them.
    pub owner: PrincipalId,
}

pub type Binds = Codes<Pending>;
