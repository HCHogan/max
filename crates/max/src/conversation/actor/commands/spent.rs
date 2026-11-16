//! What a conversation's model calls used, for `/status`: their tokens
//! in a window of time, and what they cost at the models' list prices.

use std::fmt;

use max_db::usage::Used;

use crate::config::Price;

/// A window's calls, summed.
#[derive(Debug, Default, PartialEq)]
pub(super) struct Spent {
    input: i64,
    /// Of the input, how much hit the cache.
    cached: i64,
    output: i64,
    /// US dollars, of the calls whose model has a price...
    cost: f64,
    /// ...which some had none.
    unpriced: bool,
}

impl Spent {
    /// The calls of `used`, priced by `price` from the provider and the
    /// model.
    pub(super) fn sum(used: &[Used], price: impl Fn(&str, &str) -> Option<Price>) -> Self {
        let mut spent = Self::default();
        for used in used {
            spent.input += used.input;
            spent.cached += used.cached;
            spent.output += used.output;
            match price(&used.provider, &used.model) {
                Some(price) => spent.cost += cost(used, price),
                None => spent.unpriced = true,
            }
        }
        spent
    }
}

/// In US dollars: input read from the cache at its own price, the rest
/// at the input's.
fn cost(used: &Used, price: Price) -> f64 {
    let fresh = (used.input - used.cached).max(0) as f64;
    let cached = used.cached as f64 * price.cached.unwrap_or(price.input);
    (fresh * price.input + cached + used.output as f64 * price.output) / 1e6
}

/// `in 34.2M · out 360k · cache 79.8% · $5.31`, the cache's the share of
/// the input that hit it; the cost is a floor, `≥ $5.31`, when some calls
/// had no price.
impl fmt::Display for Spent {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.input == 0 && self.output == 0 {
            return f.write_str("none");
        }
        write!(f, "in {} · out {}", tokens(self.input), tokens(self.output))?;
        if self.input > 0 {
            let rate = self.cached as f64 * 100.0 / self.input as f64;
            write!(f, " · cache {rate:.1}%")?;
        }
        f.write_str(" · ")?;
        if self.unpriced {
            f.write_str("≥ ")?;
        }
        write!(f, "${:.2}", self.cost)
    }
}

/// A count of tokens, to three figures: 950, 1.23k, 12.3k, 437M.
fn tokens(count: i64) -> String {
    let count = u64::try_from(count).unwrap_or(0);
    super::figures(count, 1000.0, &["k", "M", "B"])
}
