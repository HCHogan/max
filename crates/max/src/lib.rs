//! Max, a group chat agent: the services, the conversation actors and the
//! platform adapters around max-core's state machines. The binary in
//! main.rs is a thin command line over this.

/// The commit max was built from: the flake sets `MAX_COMMIT`, and a
/// cargo build outside it says dev.
pub const COMMIT: &str = match option_env!("MAX_COMMIT") {
    Some(commit) => commit,
    None => "dev",
};

pub mod bind;
pub mod command;
pub mod config;
pub mod conversation;
pub mod embedding;
pub mod historian;
pub mod inbound;
pub mod job;
pub mod llm;
pub mod mcp;
pub mod media;
pub mod qq;
pub mod recall;
pub mod scope;
pub mod search;
pub mod table;
pub mod tokens;
pub mod tools;
pub mod vm;
pub mod worker;
