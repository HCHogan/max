//! A run's snapshot is its inputs, and replaying them is the only way back.

use serde::{Deserialize, Serialize};

use super::{Context, Input, Rejected, Run, RunSpec};

/// Bumped whenever the same inputs would lead somewhere else. A snapshot
/// from another version doesn't replay.
pub const CORE_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct RunRecord {
    pub core_version: u32,
    pub spec: RunSpec,
    pub base: Context,
    pub first: Vec<Input>,
    pub inputs: Vec<Input>,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ReplayError {
    #[error("the snapshot is from core version {found}, this is {CORE_VERSION}")]
    Version { found: u32 },
    #[error("input {index} doesn't fit: {rejected}")]
    Rejected { index: usize, rejected: Rejected },
}

impl Run {
    pub fn snapshot(&self) -> RunRecord {
        RunRecord {
            core_version: CORE_VERSION,
            spec: self.spec.clone(),
            base: self.base.clone(),
            first: self.first.clone(),
            inputs: self.log.clone(),
        }
    }

    pub fn replay(record: &RunRecord) -> Result<Self, ReplayError> {
        if record.core_version != CORE_VERSION {
            return Err(ReplayError::Version {
                found: record.core_version,
            });
        }
        let mut run = Run::new(
            record.spec.clone(),
            record.base.clone(),
            record.first.clone(),
        );
        for (index, input) in record.inputs.iter().enumerate() {
            run.apply(input.clone())
                .map_err(|rejected| ReplayError::Rejected { index, rejected })?;
        }
        Ok(run)
    }
}
