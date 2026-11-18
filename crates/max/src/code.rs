//! Codes said once: an owner asks for one in one conversation and says it
//! in another, which ties the two, for `/bind` and for `/link`. Codes live
//! in memory: a restart forgets them.

use std::collections::HashMap;
use std::fmt;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const VALID: Duration = Duration::from_secs(600);

/// The codes out, and what each is for.
pub struct Codes<T> {
    codes: Mutex<HashMap<String, Issued<T>>>,
}

/// By how many are out: a code is for whoever says it.
impl<T> fmt::Debug for Codes<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let out = self.codes.lock().map_or(0, |codes| codes.len());
        f.debug_struct("Codes").field("out", &out).finish()
    }
}

/// A code's meaning: what it is for, and when it was issued.
struct Issued<T> {
    what: T,
    at: Instant,
}

impl<T> Issued<T> {
    fn valid(&self, now: Instant) -> bool {
        now < self.at + VALID
    }
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
        codes.retain(|_, issued| issued.valid(now));
        loop {
            // A code lets whoever says it first tie two conversations:
            // from the generator the VMs' keys are made with, which the
            // OS seeds.
            let code = format!("{:06}", rand::random_range(0..1_000_000_u32));
            if !codes.contains_key(&code) {
                codes.insert(code.clone(), Issued { what, at: now });
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
        let issued = codes.remove(code.trim())?;
        issued.valid(now).then_some(issued.what)
    }

    /// What the code is for, without using it.
    pub fn peek(&self, code: &str, now: Instant) -> Option<T> {
        let codes = self
            .codes
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let issued = codes.get(code.trim())?;
        issued.valid(now).then(|| issued.what.clone())
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
