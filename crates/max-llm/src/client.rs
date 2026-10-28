//! Sends a request to a provider and reads the response as it streams.
//! One call is one attempt; whether to try again is the caller's choice,
//! since text already said can't be taken back.

use std::collections::VecDeque;
use std::fmt;
use std::future::Future;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use futures_util::{Stream, StreamExt};
use max_core::item::{ModelOutput, Protocol};
use max_core::run::Request;
use sse_stream::{Sse, SseStream};
use tokio::time::{Instant, Sleep, sleep, timeout};

use crate::{Error, Event, Options, chat, responses};

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
    pub async fn call(&self, request: &Request, options: &Options) -> Result<Call, Error> {
        let model = request.model.clone();
        let (path, body, parser) = match model.protocol {
            Protocol::Responses => (
                "/responses",
                responses::body(request, options),
                Parser::Responses(responses::Parser::new(model)),
            ),
            Protocol::Chat => (
                "/chat/completions",
                chat::body(request, options),
                Parser::Chat(chat::Parser::new(model)),
            ),
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
        let response = timeout(idle, http.send())
            .await
            .map_err(|_| Error::Idle(idle))?
            .map_err(Error::Connect)?;

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
        Ok(Call {
            events: Box::pin(SseStream::from_bytes_stream(body)),
            parser,
            idle,
            pending: VecDeque::new(),
        })
    }
}

/// A response on its way in.
pub struct Call {
    events: Pin<Box<dyn Stream<Item = Result<Sse, sse_stream::Error>> + Send>>,
    parser: Parser,
    idle: Duration,
    pending: VecDeque<Event>,
}

impl Call {
    /// The next piece of the response, or `None` once no more is coming.
    pub async fn next(&mut self) -> Result<Option<Event>, Error> {
        loop {
            if let Some(event) = self.pending.pop_front() {
                return Ok(Some(event));
            }
            if self.parser.finished() {
                return Ok(None);
            }
            match self.events.next().await {
                None => return Ok(None),
                Some(Err(error)) => return Err(self.broken(&error)),
                Some(Ok(sse)) => {
                    if let Some(data) = sse.data {
                        self.pending.extend(self.parser.event(&data)?);
                    }
                }
            }
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
    fn event(&mut self, data: &str) -> Result<Vec<Event>, Error> {
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
