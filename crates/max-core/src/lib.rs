//! Max's pure logic: message types, rendering for the model, the segmenter,
//! the core and intent state machines, request construction and decay.
//!
//! Nothing here does I/O or reads the clock. The only dependencies allowed
//! are serde, serde_json, thiserror and chrono without its `clock` feature;
//! the flake's `max-core-deps` check enforces that.

pub mod faces;
pub mod ids;
pub mod item;
pub mod message;
pub mod render;
pub mod segment;
pub mod tools;
