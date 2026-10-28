//! `!bind` codes. An owner asks for one in a private chat, for an old
//! conversation or a new one, and says it in a QQ group to bind the group
//! to it. Codes live in memory: a restart forgets them.

use std::collections::HashMap;
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use max_core::ids::{ConversationId, PrincipalId};

const VALID: Duration = Duration::from_secs(600);

/// What a code binds a group to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pending {
    /// None for a new conversation.
    pub conversation: Option<ConversationId>,
    /// Who asked: their account in the group is merged into them.
    pub owner: PrincipalId,
}

#[derive(Default)]
pub struct Binds {
    codes: Mutex<HashMap<String, (Pending, Instant)>>,
}

impl Binds {
    /// A six-digit code, valid for ten minutes.
    pub fn issue(&self, pending: Pending, now: Instant) -> String {
        let mut codes = self
            .codes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        codes.retain(|_, (_, at)| now < *at + VALID);
        loop {
            // RandomState's keys come from the OS: enough for a code that
            // is said once and lives ten minutes.
            let mut hasher = RandomState::new().build_hasher();
            let clock = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default();
            hasher.write_u128(clock.as_nanos());
            let code = format!("{:06}", hasher.finish() % 1_000_000);
            if !codes.contains_key(&code) {
                codes.insert(code.clone(), (pending, now));
                return code;
            }
        }
    }

    /// The code's binding, once: a used or expired code is gone.
    pub fn redeem(&self, code: &str, now: Instant) -> Option<Pending> {
        let mut codes = self
            .codes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (pending, at) = codes.remove(code.trim())?;
        (now < at + VALID).then_some(pending)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_code_works_once_and_not_for_long() {
        let binds = Binds::default();
        let now = Instant::now();
        let pending = Pending {
            conversation: Some(ConversationId(3)),
            owner: PrincipalId(1),
        };
        let code = binds.issue(pending, now);
        assert_eq!(code.len(), 6);
        assert!(code.bytes().all(|b| b.is_ascii_digit()));
        assert_eq!(binds.redeem("000000x", now), None);
        assert_eq!(binds.redeem(&format!(" {code}\n"), now), Some(pending));
        assert_eq!(binds.redeem(&code, now), None);

        let code = binds.issue(pending, now);
        assert_eq!(binds.redeem(&code, now + VALID), None);
        let codes: std::collections::HashSet<_> =
            (0..50).map(|_| binds.issue(pending, now)).collect();
        assert_eq!(codes.len(), 50);
    }
}
