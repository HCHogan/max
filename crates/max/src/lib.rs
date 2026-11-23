//! Max, a group chat agent: the services and the conversation actors
//! around max-core's state machines, and what a platform's adapter
//! implements (`adapter`). The binary, max-cli, is a thin command line
//! over this.

/// The commit max was built from: the flake sets `MAX_COMMIT`, and a
/// cargo build outside it says dev.
pub const COMMIT: &str = match option_env!("MAX_COMMIT") {
    Some(commit) => commit,
    None => "dev",
};

pub mod adapter;
pub mod bind;
pub mod causes;
pub mod code;
pub mod command;
pub mod config;
pub mod conversation;
pub mod embedding;
pub mod inbound;
pub mod llm;
pub mod media;
pub mod recall;
pub mod scope;
pub mod search;
pub mod service;
pub mod table;
pub mod tokens;
pub mod tools;
pub mod vm;
pub mod worker;
