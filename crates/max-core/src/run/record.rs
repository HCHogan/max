//! A run's snapshot is its inputs, and replaying them is the only way back.

use serde::{Deserialize, Serialize};

use super::{Context, InFlight, Input, Rejected, Run, RunSpec, SYNTHESIZED_TOKENS};
use crate::item::ToolOutput;

/// Bumped whenever the same inputs would lead somewhere else. A snapshot
/// from another version isn't replayed: its turn expires instead.
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
    #[error("the run had already ended")]
    Ended,
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

    /// Replays a suspended run and closes what was in flight when it
    /// stopped: a model call is abandoned, to be made again, and each
    /// running tool call gets a result saying it is unknown. These are
    /// inputs like any other, so the final snapshot replays from the start.
    pub fn resume(record: &RunRecord) -> Result<Self, ReplayError> {
        let mut run = Run::replay(record)?;
        if run.ended {
            return Err(ReplayError::Ended);
        }
        let close = |run: &mut Run, input| {
            let index = run.log.len();
            run.apply(input)
                .map_err(|rejected| ReplayError::Rejected { index, rejected })
        };
        if run.in_flight == InFlight::Model {
            close(
                &mut run,
                Input::PartialOutput {
                    text: String::new(),
                    tokens: 0,
                },
            )?;
        }
        for call in run.outstanding.clone() {
            let output =
                ToolOutput::text("进程重启了，这个调用的结果未知", true, SYNTHESIZED_TOKENS);
            close(&mut run, Input::ToolResult { call, output })?;
        }
        Ok(run)
    }
}
