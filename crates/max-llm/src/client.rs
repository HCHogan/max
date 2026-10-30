//! Sends a request to a provider and reads the response as it streams.
//! One call is one attempt; whether to try again is the caller's choice,
//! since text already said can't be taken back.

use std::collections::VecDeque;
use std::fmt;
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use futures_util::{Stream, StreamExt, stream};
use max_core::item::{ModelOutput, ModelTag, Protocol, Timing};
use max_core::run::Request;
use sse_stream::{Sse, SseStream};
use tokio::time::{Instant, Sleep, sleep, timeout};

use crate::{Error, Options, Pictures, chat, responses};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// How much of an error body to keep.
const ERROR_BODY: usize = 2000;

/// How to reach a provider.
#[derive(Clone)]
pub struct Provider {
    /// Up to and including `/v1`.
    pub base_url: String,
    pub api_key: Option<String>,
    pub headers: Vec<(String, String)>,
    /// The longest wait for anything from the provider, the response's
    /// headers included. There is no limit on the whole call.
    pub idle_timeout: Duration,
}

impl fmt::Debug for Provider {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Provider")
            .field("base_url", &self.base_url)
            .field("idle_timeout", &self.idle_timeout)
            .finish_non_exhaustive()
    }
}

pub struct Client {
    http: reqwest::Client,
    provider: Provider,
}

impl Client {
    pub fn new(provider: Provider) -> Result<Self, Error> {
        let http = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .build()
            .map_err(Error::Connect)?;
        Ok(Self { http, provider })
    }

    /// Sends the request, in the protocol of its model, and waits for the
    /// response to start.
    pub async fn call(
        &self,
        request: &Request,
        options: &Options,
        pictures: &Pictures,
    ) -> Result<Call, Error> {
        let (path, body) = match request.model.protocol {
            Protocol::Responses => ("/responses", responses::body(request, options, pictures)),
            Protocol::Chat => ("/chat/completions", chat::body(request, options, pictures)),
        };
        let base = self.provider.base_url.trim_end_matches('/');
        let mut http = self.http.post(format!("{base}{path}")).json(&body);
        if let Some(key) = &self.provider.api_key {
            http = http.bearer_auth(key);
        }
        for (name, value) in &self.provider.headers {
            http = http.header(name, value);
        }
        let idle = self.provider.idle_timeout;
        let sent = Instant::now();
        let response = timeout(idle, http.send())
            .await
            .map_err(|_| Error::Idle(idle))?
            .map_err(Error::Connect)?;
        let headed = Instant::now();

        let status = response.status();
        let json = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.contains("json"));
        if !status.is_success() || json {
            let text = timeout(idle, response.text())
                .await
                .map_err(|_| Error::Idle(idle))?
                .map_err(|error| Error::Body(error.to_string()))?;
            if !status.is_success() {
                return Err(Error::Status {
                    status: status.as_u16(),
                    body: text.chars().take(ERROR_BODY).collect(),
                });
            }
            // Some gateways answer a failed stream with a plain JSON error.
            let body: serde_json::Value = serde_json::from_str(&text).map_err(Error::malformed)?;
            return Err(match body.get("error") {
                Some(_) => Error::provider(&body),
                None => Error::Malformed(format!("expected a stream, got {text:.200}")),
            });
        }

        let body = Watched {
            body: Box::pin(response.bytes_stream()),
            limit: idle,
            deadline: Box::pin(sleep(idle)),
        };
        let events = SseStream::from_bytes_stream(body);
        Ok(Call::new(
            request.model.clone(),
            Box::pin(events),
            idle,
            (sent, headed),
        ))
    }
}

type Events = Pin<Box<dyn Stream<Item = Result<Sse, sse_stream::Error>> + Send>>;

/// A response on its way in.
pub struct Call {
    events: Events,
    parser: Parser,
    idle: Duration,
    /// Text parsed and not yet taken.
    pending: VecDeque<String>,
    /// When the request was sent, and when something last arrived.
    sent: Instant,
    arrived: Instant,
    first: Option<Duration>,
    quiet: Duration,
}

impl Call {
    /// `at`: when the request was sent, and when the response's headers
    /// came.
    fn new(model: ModelTag, events: Events, idle: Duration, at: (Instant, Instant)) -> Self {
        let (sent, headed) = at;
        let parser = match model.protocol {
            Protocol::Responses => Parser::Responses(responses::Parser::new(model)),
            Protocol::Chat => Parser::Chat(chat::Parser::new(model)),
        };
        Self {
            events,
            parser,
            idle,
            pending: VecDeque::new(),
            sent,
            arrived: headed,
            first: None,
            quiet: headed - sent,
        }
    }

    /// A response recorded earlier, read as if it were arriving.
    pub fn replay(model: ModelTag, recorded: Vec<u8>) -> Self {
        let body = stream::iter([Ok::<_, io::Error>(VecDeque::from(recorded))]);
        let events = SseStream::from_bytes_stream(body);
        let now = Instant::now();
        Self::new(model, Box::pin(events), Duration::MAX, (now, now))
    }

    /// The next text the model wrote, to be said, or `None` once no more
    /// is coming.
    pub async fn next(&mut self) -> Result<Option<String>, Error> {
        loop {
            if let Some(text) = self.pending.pop_front() {
                return Ok(Some(text));
            }
            if self.parser.finished() {
                return Ok(None);
            }
            let event = self.events.next().await;
            let now = Instant::now();
            self.quiet = self.quiet.max(now - self.arrived);
            self.arrived = now;
            match event {
                None => return Ok(None),
                Some(Err(error)) => return Err(self.broken(&error)),
                Some(Ok(sse)) => {
                    if let Some(data) = sse.data {
                        self.pending.extend(self.parser.event(&data)?);
                        if self.first.is_none() && self.parser.started() {
                            self.first = Some(now - self.sent);
                        }
                    }
                }
            }
        }
    }

    /// How the call has gone in time; once [`Call::next`] has returned
    /// `None`, how it went.
    pub fn timing(&self) -> Timing {
        Timing {
            first: self.first,
            took: self.arrived - self.sent,
            quiet: self.quiet,
        }
    }

    /// What the model produced, once [`Call::next`] has returned `None`;
    /// an error if the response never completed.
    pub fn finish(self) -> Result<ModelOutput, Error> {
        match self.parser {
            Parser::Responses(parser) => parser.finish(),
            Parser::Chat(parser) => parser.finish(),
        }
    }

    fn broken(&self, error: &sse_stream::Error) -> Error {
        match error {
            sse_stream::Error::Body(body) => match body.downcast_ref::<Broken>() {
                Some(Broken::Idle) => Error::Idle(self.idle),
                _ => Error::Body(body.to_string()),
            },
            other => Error::malformed(other),
        }
    }
}

#[derive(Debug)]
enum Parser {
    Responses(responses::Parser),
    Chat(chat::Parser),
}

impl Parser {
    fn event(&mut self, data: &str) -> Result<Vec<String>, Error> {
        match self {
            Self::Responses(parser) => parser.event(data),
            Self::Chat(parser) => parser.event(data),
        }
    }

    fn finished(&self) -> bool {
        match self {
            Self::Responses(parser) => parser.finished(),
            Self::Chat(parser) => parser.finished(),
        }
    }

    fn started(&self) -> bool {
        match self {
            Self::Responses(parser) => parser.started(),
            Self::Chat(parser) => parser.started(),
        }
    }
}

/// A response body that fails once nothing has arrived for too long.
/// Any bytes count, so a provider's keep-alive comments keep it going.
struct Watched<S> {
    body: S,
    limit: Duration,
    deadline: Pin<Box<Sleep>>,
}

#[derive(Debug, thiserror::Error)]
enum Broken {
    #[error(transparent)]
    Http(reqwest::Error),
    #[error("nothing arrived in time")]
    Idle,
}

impl<S, T> Stream for Watched<S>
where
    S: Stream<Item = reqwest::Result<T>> + Unpin,
{
    type Item = Result<T, Broken>;

    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = &mut *self;
        match this.body.poll_next_unpin(cx) {
            Poll::Ready(item) => {
                let deadline = Instant::now() + this.limit;
                this.deadline.as_mut().reset(deadline);
                Poll::Ready(item.map(|item| item.map_err(Broken::Http)))
            }
            Poll::Pending => match this.deadline.as_mut().poll(cx) {
                Poll::Ready(()) => Poll::Ready(Some(Err(Broken::Idle))),
                Poll::Pending => Poll::Pending,
            },
        }
    }
}

#[cfg(test)]
mod tests;
