//! QQ's official bot API (QQ 开放平台): access tokens, the WebSocket
//! gateway, event and REST types, sending and uploading.
//!
//! This crate knows nothing about Max. Mapping QQ messages to Max's nodes
//! happens in the `max` crate.

pub mod api;
pub mod event;
pub mod gateway;
pub mod message;

pub use api::{Chat, Client, Credentials, Error};
pub use event::{Dispatch, Event};
pub use message::{Body, Outgoing, Reply, Sent};
