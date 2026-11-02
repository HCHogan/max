//! Max's pure logic: message types, rendering for the model, the segmenter,
//! the core and intent state machines, and request construction.
//!
//! Nothing here does I/O or reads the clock. The only dependencies allowed
//! are serde, serde_json, thiserror and chrono without its `clock` feature;
//! the flake's `max-core-deps` check enforces that.

pub mod ids;
pub mod intent;
pub mod item;
pub mod message;
pub mod project;
pub mod prompt;
pub mod render;
pub mod run;
pub mod segment;
pub mod tools;
