//! Codes said once: an owner asks for one in one conversation and says it
//! in another, which ties the two, for `/bind` and for `/link`. Codes live
//! in memory: a restart forgets them.

use std::collections::HashMap;
use std::collections::hash_map::RandomState;
use std::hash::{BuildHasher, Hasher};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const VALID: Duration = Duration::from_secs(600);

/// The codes out, and what each is for.
pub struct Codes<T> {
    codes: Mutex<HashMap<String, (T, Instant)>>,
}

impl<T> Default for Codes<T> {
    fn default() -> Self {
        Self {
            codes: Mutex::default(),
        }
    }
}

impl<T: Clone> Codes<T> {
    /// A six-digit code, valid for ten minutes.
    pub fn issue(&self, what: T, now: Instant) -> String {
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
                codes.insert(code.clone(), (what, now));
                return code;
            }
        }
    }

    /// What the code is for, once: a used or expired code is gone.
    pub fn redeem(&self, code: &str, now: Instant) -> Option<T> {
        let mut codes = self
            .codes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (what, at) = codes.remove(code.trim())?;
        (now < at + VALID).then_some(what)
    }

    /// What the code is for, without using it.
    pub fn peek(&self, code: &str, now: Instant) -> Option<T> {
        let codes = self
            .codes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (what, at) = codes.get(code.trim())?;
        (now < *at + VALID).then(|| what.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_code_works_once_and_not_for_long() {
        let codes = Codes::default();
        let now = Instant::now();
        let code = codes.issue(3, now);
        assert_eq!(code.len(), 6);
        assert!(code.bytes().all(|b| b.is_ascii_digit()));
        assert_eq!(codes.redeem("000000x", now), None);
        // A look doesn't use it.
        assert_eq!(codes.peek(&code, now), Some(3));
        assert_eq!(codes.redeem(&format!(" {code}\n"), now), Some(3));
        assert_eq!(codes.peek(&code, now), None);
        assert_eq!(codes.redeem(&code, now), None);

        let code = codes.issue(3, now);
        assert_eq!(codes.peek(&code, now + VALID), None);
        assert_eq!(codes.redeem(&code, now + VALID), None);
        let many: std::collections::HashSet<_> = (0..50).map(|_| codes.issue(3, now)).collect();
        assert_eq!(many.len(), 50);
    }
}
