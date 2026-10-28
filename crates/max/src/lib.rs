//! Max, a group chat agent: the services, the conversation actors and the
//! platform adapters around max-core's state machines. The binary in
//! main.rs is a thin command line over this.

pub mod bind;
pub mod command;
pub mod config;
pub mod conversation;
pub mod inbound;
pub mod llm;
pub mod qq;
pub mod scope;
pub mod table;
pub mod tokens;
