//! Max, a group chat agent: the services and the conversation actors
//! around max-core's state machines, and what a platform's adapter
//! implements (`adapter`). The binary, max-cli, is a thin command line
//! over this.

/// The version max was built as: the day (UTC) and the commit of the
/// source, `20261123.4999d8f`, which the flake sets as `MAX_VERSION`. A
/// cargo build outside it is dev.
pub const VERSION: &str = match option_env!("MAX_VERSION") {
    Some(version) => version,
    None => "dev",
};

pub mod adapter;
pub mod bind;
pub mod causes;
pub mod code;
pub mod command;
pub mod config;
pub mod conversation;
pub mod inbound;
pub mod llm;
pub mod media;
pub mod scope;
pub mod search;
pub mod service;
pub mod table;
pub mod tokens;
pub mod tools;
pub mod vm;
pub mod worker;
