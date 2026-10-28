//! Which level each summary renders at: magic-context's decay curve.
//!
//! Older summaries render shorter, an important one stays detailed longer,
//! and when the whole set would overflow its budget every summary moves
//! toward the short end together. The inputs (rank, importance, budget)
//! only change when the historian publishes, so between publishes the
//! summary block stays byte for byte the same.

/// A summary's three levels, written once by the historian.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    /// p1, the full account.
    Full,
    /// p2, a short one.
    Brief,
    /// p3, one line.
    Line,
}

/// What decay needs of a summary: its importance and each level's tokens.
/// An imported summary may have only the full level.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Costs {
    /// 1 to 100: how slowly the summary decays.
    pub importance: u8,
    pub full: u32,
    pub brief: Option<u32>,
    pub line: Option<u32>,
}

/// Half-life in summaries at importance 50 and pressure 1.
pub const H50: f64 = 24.0;
/// Importance points that double the half-life.
pub const D: f64 = 25.0;
/// Pressure below this relaxes no further.
pub const P_FLOOR: f64 = 0.1;
/// Where the full level gives way to the brief one, the brief to the line,
/// and the line to nothing. magic-context's values, from its own levels'
/// costs; our line covers its third and fourth. To recompute once v1 has
/// summaries of ours.
pub const Z: [f64; 3] = [0.201, 0.729, 2.587];

/// The level a summary would have, `rank` summaries from the newest (the
/// newest is 0); None means archived: not rendered, still searchable.
pub fn natural(rank: usize, importance: u8, pressure: f64) -> Option<Level> {
    let importance = f64::from(importance.clamp(1, 100));
    let half_life = H50 * 2f64.powf((importance - 50.0) / D) / pressure.max(P_FLOOR);
    let z = rank as f64 / half_life;
    if z < Z[0] {
        Some(Level::Full)
    } else if z < Z[1] {
        Some(Level::Brief)
    } else if z < Z[2] {
        Some(Level::Line)
    } else {
        None
    }
}

impl Costs {
    /// The level that renders for `level`: a missing one falls back to
    /// the nearest more detailed one.
    pub fn available(&self, level: Level) -> Level {
        match level {
            Level::Line if self.line.is_some() => Level::Line,
            Level::Line | Level::Brief if self.brief.is_some() => Level::Brief,
            _ => Level::Full,
        }
    }

    pub fn tokens(&self, level: Level) -> u32 {
        match self.available(level) {
            Level::Full => self.full,
            Level::Brief => self.brief.unwrap_or(self.full),
            Level::Line => self.line.unwrap_or(self.full),
        }
    }
}

/// What the summaries cost at pressure 1, over the budget. Halving every
/// half-life roughly halves the cost, so rendering at this pressure lands
/// near the budget.
pub fn pressure(summaries: &[Costs], budget: u32) -> f64 {
    if budget == 0 {
        return 1.0;
    }
    let natural_cost: u64 = ranked(summaries)
        .filter_map(|(rank, costs)| {
            natural(rank, costs.importance, 1.0).map(|level| u64::from(costs.tokens(level)))
        })
        .sum();
    (natural_cost as f64 / f64::from(budget)).max(P_FLOOR)
}

/// The level each summary renders at, oldest first like the input; None
/// for archived ones.
pub fn levels(summaries: &[Costs], budget: u32) -> Vec<Option<Level>> {
    let pressure = pressure(summaries, budget);
    let mut levels: Vec<Option<Level>> = ranked(summaries)
        .map(|(rank, costs)| {
            natural(rank, costs.importance, pressure).map(|level| costs.available(level))
        })
        .collect();
    levels.reverse();
    levels
}

/// Newest first, with each one's rank.
fn ranked(summaries: &[Costs]) -> impl Iterator<Item = (usize, &Costs)> {
    summaries.iter().rev().enumerate()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn costs(importance: u8) -> Costs {
        Costs {
            importance,
            full: 300,
            brief: Some(100),
            line: Some(20),
        }
    }

    #[test]
    fn the_newest_is_full_and_age_only_shortens() {
        for pressure in [0.1, 1.0, 5.0] {
            assert_eq!(natural(0, 1, pressure), Some(Level::Full));
        }
        let mut last = Some(Level::Full);
        for rank in 0..200 {
            let level = natural(rank, 50, 1.0);
            assert!(
                level.is_none() || last.is_some() && level >= last,
                "rank {rank}"
            );
            last = level;
        }
        assert_eq!(natural(5, 50, 1.0), Some(Level::Brief));
        assert_eq!(natural(20, 50, 1.0), Some(Level::Line));
        assert_eq!(natural(70, 50, 1.0), None);
        assert_eq!(natural(70, 100, 1.0), Some(Level::Line));
        assert_eq!(natural(1_000, 100, 1.0), None);
    }

    #[test]
    fn importance_and_pressure_move_the_curve() {
        assert_eq!(natural(10, 25, 1.0), Some(Level::Line));
        assert_eq!(natural(10, 75, 1.0), Some(Level::Brief));
        assert_eq!(natural(10, 50, 8.0), None);
        assert_eq!(natural(10, 50, 0.01), Some(Level::Full));
    }

    #[test]
    fn missing_levels_fall_back_to_more_detail() {
        let imported = Costs {
            importance: 50,
            full: 500,
            brief: None,
            line: None,
        };
        assert_eq!(imported.available(Level::Line), Level::Full);
        assert_eq!(imported.tokens(Level::Brief), 500);
        let no_line = Costs {
            line: None,
            ..costs(50)
        };
        assert_eq!(no_line.available(Level::Line), Level::Brief);
    }

    #[test]
    fn pressure_keeps_the_block_near_its_budget() {
        let summaries: Vec<Costs> = (0..200).map(|_| costs(50)).collect();
        let cost = |levels: &[Option<Level>]| -> u32 {
            levels
                .iter()
                .zip(&summaries)
                .filter_map(|(level, costs)| level.map(|level| costs.tokens(level)))
                .sum()
        };
        let shown =
            |levels: &[Option<Level>]| levels.iter().filter(|level| level.is_some()).count();
        // 5 full, 13 brief and 45 lines cost 3,700: pressure 1.
        let natural = levels(&summaries, 3_700);
        assert_eq!(natural.last(), Some(&Some(Level::Full)));
        assert_eq!((shown(&natural), cost(&natural)), (63, 3_700));
        let tight = levels(&summaries, 1_000);
        assert!(cost(&tight) < 1_400, "{}", cost(&tight));
        // Pressure bottoms out at 0.1: a tenth of the natural cost.
        assert_eq!(shown(&levels(&summaries, 1_000_000)), 200);
        assert_eq!(pressure(&[], 1_000), P_FLOOR);
    }
}
