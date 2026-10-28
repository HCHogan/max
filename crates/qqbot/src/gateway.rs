//! The gateway session as a state machine: frames and time in, frames to
//! send and events out. [`crate::connection`] does the I/O.
//!
//! The protocol is Discord's: Hello gives the heartbeat interval, Identify
//! starts a session and Resume picks one up after a dropped connection,
//! replaying what was missed after the last sequence number seen.

use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::event::{Dispatch, Event};

/// Group and private messages, and the events around them.
pub const GROUP_AND_C2C: u32 = 1 << 25;

const DISPATCH: u8 = 0;
const HEARTBEAT: u8 = 1;
const IDENTIFY: u8 = 2;
const RESUME: u8 = 6;
const RECONNECT: u8 = 7;
const INVALID_SESSION: u8 = 9;
const HELLO: u8 = 10;
const HEARTBEAT_ACK: u8 = 11;

/// What the driver should do.
#[derive(Clone, Debug, PartialEq)]
pub enum Out {
    /// Send [`identify`].
    Identify,
    /// Send [`resume`].
    Resume {
        session_id: String,
        seq: u64,
    },
    /// Send [`heartbeat`].
    Heartbeat {
        seq: Option<u64>,
    },
    /// A session started or resumed.
    Ready {
        resumed: bool,
    },
    Dispatch(Box<Dispatch>),
    /// Drop the connection and connect again.
    Reconnect,
}

/// After a connection ends: connect again, or stop for good.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum After {
    Reconnect,
    Stop(Fatal),
}

/// Close codes that reconnecting won't fix.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Fatal {
    #[error("QQ refused the token (close code {0})")]
    Token(u16),
    #[error("QQ refused the session's settings, such as the intents (close code {0})")]
    Settings(u16),
    #[error("the bot is offline, banned or not allowed out of the sandbox (close code {0})")]
    Bot(u16),
}

#[derive(Debug, thiserror::Error)]
#[error("a gateway frame that doesn't parse: {0}")]
pub struct BadFrame(#[from] serde_json::Error);

#[derive(Debug)]
pub struct Session {
    intents: u32,
    /// The session to resume, once READY has named it.
    session_id: Option<String>,
    seq: Option<u64>,
    interval: Option<Duration>,
    next_beat: Option<Instant>,
    /// A heartbeat went out and no ACK came back yet.
    awaiting_ack: bool,
}

#[derive(Deserialize)]
struct Frame {
    op: u8,
    #[serde(default)]
    d: Value,
    #[serde(default)]
    s: Option<u64>,
    #[serde(default)]
    t: Option<String>,
    #[serde(default)]
    id: Option<String>,
}

impl Session {
    pub fn new(intents: u32) -> Self {
        Self {
            intents,
            session_id: None,
            seq: None,
            interval: None,
            next_beat: None,
            awaiting_ack: false,
        }
    }

    pub fn intents(&self) -> u32 {
        self.intents
    }

    /// When [`Session::tick`] is due.
    pub fn deadline(&self) -> Option<Instant> {
        self.next_beat
    }

    pub fn receive(&mut self, text: &str, now: Instant) -> Result<Vec<Out>, BadFrame> {
        let frame: Frame = serde_json::from_str(text)?;
        Ok(match frame.op {
            HELLO => self.hello(&frame.d, now),
            DISPATCH => self.dispatch(frame),
            HEARTBEAT => vec![Out::Heartbeat { seq: self.seq }],
            HEARTBEAT_ACK => {
                self.awaiting_ack = false;
                Vec::new()
            }
            RECONNECT => vec![Out::Reconnect],
            INVALID_SESSION => {
                if frame.d != Value::Bool(true) {
                    self.forget();
                }
                vec![Out::Reconnect]
            }
            _ => Vec::new(),
        })
    }

    /// A heartbeat when one is due. If the last one was never
    /// acknowledged, the connection is dead without having closed.
    pub fn tick(&mut self, now: Instant) -> Vec<Out> {
        let (Some(due), Some(interval)) = (self.next_beat, self.interval) else {
            return Vec::new();
        };
        if now < due {
            return Vec::new();
        }
        if self.awaiting_ack {
            self.next_beat = None;
            return vec![Out::Reconnect];
        }
        self.awaiting_ack = true;
        self.next_beat = Some(now + interval);
        vec![Out::Heartbeat { seq: self.seq }]
    }

    /// The connection ended, with the server's close code if it sent one.
    pub fn closed(&mut self, code: Option<u16>) -> After {
        self.interval = None;
        self.next_beat = None;
        self.awaiting_ack = false;
        match code {
            Some(code @ 4004) => After::Stop(Fatal::Token(code)),
            Some(code @ 4010..=4014) => After::Stop(Fatal::Settings(code)),
            Some(code @ (4914 | 4915)) => After::Stop(Fatal::Bot(code)),
            // The session is gone: invalid, out of sequence or timed out.
            Some(4006 | 4007 | 4009) => {
                self.forget();
                After::Reconnect
            }
            _ => After::Reconnect,
        }
    }

    fn hello(&mut self, d: &Value, now: Instant) -> Vec<Out> {
        let interval = d["heartbeat_interval"].as_u64().unwrap_or(41_250);
        let interval = Duration::from_millis(interval);
        self.interval = Some(interval);
        self.next_beat = Some(now + interval);
        self.awaiting_ack = false;
        match (&self.session_id, self.seq) {
            (Some(session_id), Some(seq)) => vec![Out::Resume {
                session_id: session_id.clone(),
                seq,
            }],
            _ => vec![Out::Identify],
        }
    }

    fn dispatch(&mut self, frame: Frame) -> Vec<Out> {
        if frame.s.is_some() {
            self.seq = frame.s;
        }
        let kind = frame.t.unwrap_or_default();
        match kind.as_str() {
            "READY" => {
                self.session_id = frame.d["session_id"].as_str().map(str::to_owned);
                vec![Out::Ready { resumed: false }]
            }
            "RESUMED" => vec![Out::Ready { resumed: true }],
            _ => {
                let event = Event::parse(&kind, &frame.d);
                vec![Out::Dispatch(Box::new(Dispatch {
                    kind,
                    id: frame.id,
                    data: frame.d,
                    event,
                }))]
            }
        }
    }

    /// The next connection identifies afresh.
    fn forget(&mut self) {
        self.session_id = None;
        self.seq = None;
    }
}

pub fn identify(token: &str, intents: u32) -> String {
    json!({
        "op": IDENTIFY,
        "d": {
            "token": format!("QQBot {token}"),
            "intents": intents,
            "shard": [0, 1],
            "properties": {},
        },
    })
    .to_string()
}

pub fn resume(token: &str, session_id: &str, seq: u64) -> String {
    json!({
        "op": RESUME,
        "d": { "token": format!("QQBot {token}"), "session_id": session_id, "seq": seq },
    })
    .to_string()
}

pub fn heartbeat(seq: Option<u64>) -> String {
    json!({ "op": HEARTBEAT, "d": seq }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hello() -> String {
        json!({ "op": 10, "d": { "heartbeat_interval": 1000 } }).to_string()
    }

    fn ready(seq: u64) -> String {
        json!({
            "op": 0, "s": seq, "t": "READY",
            "d": { "version": 1, "session_id": "S1", "user": { "id": "B0T", "username": "maxx", "bot": true }, "shard": [0, 1] }
        })
        .to_string()
    }

    fn message(seq: u64) -> String {
        json!({
            "op": 0, "s": seq, "t": "GROUP_MESSAGE_CREATE", "id": format!("GROUP_MESSAGE_CREATE:{seq}"),
            "d": { "id": format!("m{seq}"), "group_openid": "G0A1", "author": { "member_openid": "M0A1" }, "content": "早" }
        })
        .to_string()
    }

    fn secs(start: Instant, s: u64) -> Instant {
        start + Duration::from_secs(s)
    }

    #[test]
    fn identify_then_dispatch() {
        let t0 = Instant::now();
        let mut session = Session::new(GROUP_AND_C2C);
        assert_eq!(session.receive(&hello(), t0).unwrap(), [Out::Identify]);
        assert_eq!(session.deadline(), Some(secs(t0, 1)));
        assert_eq!(
            session.receive(&ready(1), t0).unwrap(),
            [Out::Ready { resumed: false }]
        );
        let out = session.receive(&message(2), t0).unwrap();
        let [Out::Dispatch(dispatch)] = out.as_slice() else {
            panic!("{out:?}");
        };
        assert_eq!(dispatch.kind, "GROUP_MESSAGE_CREATE");
        assert_eq!(dispatch.id.as_deref(), Some("GROUP_MESSAGE_CREATE:2"));
        assert_eq!(dispatch.data["content"], "早");
        assert!(matches!(dispatch.event, Event::Group { at: false, .. }));
    }

    #[test]
    fn heartbeats_carry_the_last_seq_and_want_an_ack() {
        let t0 = Instant::now();
        let mut session = Session::new(GROUP_AND_C2C);
        session.receive(&hello(), t0).unwrap();
        assert!(session.tick(secs(t0, 0)).is_empty());
        assert_eq!(session.tick(secs(t0, 1)), [Out::Heartbeat { seq: None }]);
        session.receive(r#"{"op":11}"#, secs(t0, 1)).unwrap();
        session.receive(&ready(1), secs(t0, 1)).unwrap();
        session.receive(&message(5), secs(t0, 1)).unwrap();
        assert_eq!(session.tick(secs(t0, 2)), [Out::Heartbeat { seq: Some(5) }]);
        // No ACK for that one: the connection is dead.
        assert_eq!(session.tick(secs(t0, 3)), [Out::Reconnect]);
        assert_eq!(session.deadline(), None);
        // The server can ask for a heartbeat too.
        assert_eq!(
            session.receive(r#"{"op":1}"#, secs(t0, 3)).unwrap(),
            [Out::Heartbeat { seq: Some(5) }]
        );
    }

    #[test]
    fn a_dropped_connection_resumes() {
        let t0 = Instant::now();
        let mut session = Session::new(GROUP_AND_C2C);
        session.receive(&hello(), t0).unwrap();
        session.receive(&ready(1), t0).unwrap();
        session.receive(&message(2), t0).unwrap();
        assert_eq!(session.closed(Some(4900)), After::Reconnect);
        assert_eq!(session.deadline(), None);
        assert_eq!(
            session.receive(&hello(), t0).unwrap(),
            [Out::Resume {
                session_id: "S1".into(),
                seq: 2
            }]
        );
        let resumed = r#"{"op":0,"s":3,"t":"RESUMED","d":""}"#;
        assert_eq!(
            session.receive(resumed, t0).unwrap(),
            [Out::Ready { resumed: true }]
        );
        assert_eq!(session.closed(None), After::Reconnect);
        assert!(matches!(
            session.receive(&hello(), t0).unwrap()[..],
            [Out::Resume { seq: 3, .. }]
        ));
    }

    #[test]
    fn a_lost_session_identifies_afresh() {
        let t0 = Instant::now();
        let mut session = Session::new(GROUP_AND_C2C);
        session.receive(&hello(), t0).unwrap();
        session.receive(&ready(1), t0).unwrap();
        assert_eq!(session.closed(Some(4009)), After::Reconnect);
        assert_eq!(session.receive(&hello(), t0).unwrap(), [Out::Identify]);
        session.receive(&ready(1), t0).unwrap();
        // Invalid session: resumable only when it says so.
        let resumable = r#"{"op":9,"d":true}"#;
        assert_eq!(session.receive(resumable, t0).unwrap(), [Out::Reconnect]);
        session.closed(None);
        assert!(matches!(
            session.receive(&hello(), t0).unwrap()[..],
            [Out::Resume { .. }]
        ));
        let gone = r#"{"op":9,"d":false}"#;
        assert_eq!(session.receive(gone, t0).unwrap(), [Out::Reconnect]);
        session.closed(None);
        assert_eq!(session.receive(&hello(), t0).unwrap(), [Out::Identify]);
        assert_eq!(
            session.receive(r#"{"op":7}"#, t0).unwrap(),
            [Out::Reconnect]
        );
    }

    #[test]
    fn some_closes_are_final() {
        let mut session = Session::new(GROUP_AND_C2C);
        assert_eq!(session.closed(Some(4004)), After::Stop(Fatal::Token(4004)));
        assert_eq!(
            session.closed(Some(4014)),
            After::Stop(Fatal::Settings(4014))
        );
        assert_eq!(session.closed(Some(4915)), After::Stop(Fatal::Bot(4915)));
        assert_eq!(session.closed(Some(4008)), After::Reconnect);
        assert!(session.receive("not json", Instant::now()).is_err());
    }

    #[test]
    fn frames() {
        let identify: Value = serde_json::from_str(&identify("t0", GROUP_AND_C2C)).unwrap();
        assert_eq!(
            identify,
            json!({ "op": 2, "d": { "token": "QQBot t0", "intents": 1 << 25, "shard": [0, 1], "properties": {} } })
        );
        let resume: Value = serde_json::from_str(&resume("t0", "S1", 7)).unwrap();
        assert_eq!(
            resume,
            json!({ "op": 6, "d": { "token": "QQBot t0", "session_id": "S1", "seq": 7 } })
        );
        assert_eq!(heartbeat(None), r#"{"d":null,"op":1}"#);
    }
}
