//! Max's tools, which programs in a group's VM call through max's
//! service; see "The guest's calls". Each declares itself as a [`tool::Tool`].

mod ask;
mod chat_file;
mod config;
mod find_stickers;
mod forward;
mod history;
mod http;
mod mute_member;
mod program;
mod recall_message;
pub(crate) mod rows;
mod send_file;
mod send_image;
mod send_voice;
pub mod tool;
mod web_search;
pub(crate) mod work;

pub use forward::{api, router as agents};
pub use http::{Caller, Calling, Waited, Whose, router, serve};
pub use mute_member::MuteMember;

#[cfg(test)]
mod runner_tests;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use chrono::FixedOffset;
use serde::de::DeserializeOwned;
use serde_json::Value;
use sqlx::PgPool;
use tracing::warn;

use crate::conversation::{Place, Poster};
use crate::embedding::Embedder;
use crate::media::store::Store;
use crate::qq::groups::Groups;
use crate::search::Search;

/// What the tools reach, the same for every call, built once in main; an
/// `Option` is None when the configuration has none of it.
#[derive(Clone)]
pub struct Services {
    pub pool: PgPool,
    pub offset: FixedOffset,
    /// For `web_search`.
    pub search: Option<Arc<Search>>,
    /// The content store, for pictures and files sent.
    pub store: Option<Arc<Store>>,
    /// For `find_stickers`, and `history` by meaning.
    pub embedder: Option<Arc<Embedder>>,
    /// For `mute_member` and a group's name; None without QQ.
    pub groups: Option<Arc<dyn Groups>>,
}

/// Where a call comes from: the conversation whose VM made it. Every
/// call from a VM has every tool, whatever made it there: a turn's
/// program, a background command, an agent or a unit of Max's own. Max
/// decides what its programs do (2026-11-05), and the host doesn't tell
/// them apart (2026-11-12).
pub struct Context {
    pub services: Arc<Services>,
    pub place: Arc<Place>,
    /// The most tokens a page of text holds: the model's cap on one item.
    pub page_tokens: u32,
    /// The host's side of the VM's /work.
    pub work: Option<PathBuf>,
    /// A call's wall clock: the conversation's, when the call started.
    pub call_time: Duration,
    /// Says and asks things in the conversation. None for `vm-check`,
    /// and some tests: nobody to say anything for.
    pub poster: Option<Poster>,
}

#[cfg(test)]
impl Services {
    /// Only the database, at UTC+8.
    #[must_use]
    pub fn bare(pool: PgPool) -> Self {
        Self {
            pool,
            offset: crate::conversation::testing::offset(),
            search: None,
            store: None,
            embedder: None,
            groups: None,
        }
    }
}

#[cfg(test)]
impl Context {
    /// A check's in `place`: pages of 2000 tokens, no /work, and nobody
    /// to say anything for.
    #[must_use]
    pub fn check(services: Services, place: Arc<Place>) -> Self {
        Self {
            services: Arc::new(services),
            place,
            page_tokens: 2000,
            work: None,
            call_time: max_core::limits::CALL_TIME,
            poster: None,
        }
    }
}

/// A call that failed, as the program sees it.
#[derive(Debug)]
pub struct Failure {
    pub code: &'static str,
    pub message: String,
    /// What a failure of max's own came of. The program isn't told: it
    /// is for the log.
    cause: Option<sqlx::Error>,
}

/// As the program sees them: the same code and message.
impl PartialEq for Failure {
    fn eq(&self, other: &Self) -> bool {
        (self.code, &self.message) == (other.code, &other.message)
    }
}

impl Eq for Failure {}

impl Failure {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            cause: None,
        }
    }

    /// Logs what the failure came of, if it is one of max's own, where
    /// what ran `tool` is done with it.
    pub(crate) fn log(&self, tool: &str) {
        if let Some(error) = &self.cause {
            warn!(tool, %error, "a Max tool's query failed");
        }
    }

    /// Max stopped with the call in its hands: in the middle of it, or,
    /// seldom, in the moment before it would have begun it.
    #[must_use]
    pub fn closed() -> Self {
        Self::new("closed", "Max stopped before it was done")
    }
}

impl From<sqlx::Error> for Failure {
    fn from(error: sqlx::Error) -> Self {
        Self {
            cause: Some(error),
            ..Self::new("internal", "the database failed; try again later")
        }
    }
}

/// Runs the Max tool `name` for a call from a VM, within the context's
/// call time.
pub async fn call(name: &str, context: &Context, args: Value) -> Result<Value, Failure> {
    let Some(tool) = tool::find(name) else {
        return Err(unknown(name));
    };
    let done = tokio::time::timeout(context.call_time, tool.call(context, args))
        .await
        .unwrap_or_else(|_| Err(http::late(context.call_time)));
    if let Err(failure) = &done {
        failure.log(name);
    }
    done
}

/// What a caller is told of a name nothing answers to.
fn unknown(name: &str) -> Failure {
    Failure::new("unknown_tool", format!("there is no tool named {name}"))
}

fn internal() -> Failure {
    Failure::new("internal", "something went wrong; try again later")
}

fn arguments<T: DeserializeOwned>(tool: &str, args: Value) -> Result<T, Failure> {
    serde_json::from_value(args).map_err(|error| {
        Failure::new(
            "bad_arguments",
            format!("{tool}'s arguments are wrong: {error}"),
        )
    })
}

/// What stands in for the conversations' actors, where a test has none.
#[cfg(test)]
pub(crate) mod testing {
    use axum::extract::ConnectInfo;
    use axum::{Extension, Router};
    use max_core::ids::ConversationId;
    use tokio::net::TcpListener;
    use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
    use tokio_util::sync::CancellationToken;

    use super::{Caller, Context, call};
    use crate::conversation::Signal;
    use crate::scope::Scope;

    /// Serves `app` on `listener` until `stop`, every request as one
    /// from the VM of `conversation`: over TCP, which Node's fetch
    /// reaches, where the VMs' own socket says whose each is.
    pub async fn serve(
        conversation: ConversationId,
        listener: TcpListener,
        app: Router,
        stop: CancellationToken,
    ) {
        let app = app.layer(Extension(ConnectInfo(Caller(Some(conversation)))));
        let served = axum::serve(listener, app);
        let _ = served.with_graceful_shutdown(stop.cancelled_owned()).await;
    }

    /// Where a service's calls go, each run in `context` by a task of
    /// `scope`, as its conversation's actor would run it.
    pub fn answering(scope: &mut Scope, context: Context) -> UnboundedSender<Signal> {
        let (calls, mut called) = unbounded_channel();
        scope.spawn(move |_| async move {
            while let Some(signal) = called.recv().await {
                let Signal::Call {
                    conversation,
                    tool,
                    args,
                    reply,
                } = signal
                else {
                    panic!("{signal:?}");
                };
                assert_eq!(conversation, context.place.conversation);
                let _ = reply.send(call(&tool, &context, args).await);
            }
        });
        calls
    }
}
