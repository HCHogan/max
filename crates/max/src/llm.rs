//! The models Max can call, built from `[llm]`: a client per provider, the
//! models under it, and the selections. A [`Chosen`] model is all a call
//! needs; the conversation actor picks one when a core starts, and keeps it
//! for the turn.

use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use chrono::Utc;
use color_eyre::eyre::{Result, WrapErr, eyre};
use max_core::ids::{ConversationId, TurnId};
use max_core::item::{ItemKind, ModelTag, Protocol, Timing, Usage};
use max_core::run::Request;
use max_db::{PgPool, usage};
use max_llm::{Call, Options, Pictures};
use tracing::warn;

use crate::config;

/// Starts a model call. A provider's client in service; a script in tests.
pub trait Caller: Send + Sync {
    fn call<'a>(
        &'a self,
        request: &'a Request,
        options: &'a Options,
        pictures: &'a Pictures,
    ) -> Pin<Box<dyn Future<Output = Result<Call, max_llm::Error>> + Send + 'a>>;
}

impl Caller for max_llm::Client {
    fn call<'a>(
        &'a self,
        request: &'a Request,
        options: &'a Options,
        pictures: &'a Pictures,
    ) -> Pin<Box<dyn Future<Output = Result<Call, max_llm::Error>> + Send + 'a>> {
        Box::pin(max_llm::Client::call(self, request, options, pictures))
    }
}

pub struct Models {
    llm: config::Llm,
    callers: BTreeMap<String, Arc<dyn Caller>>,
}

/// A model and how to call it, for one turn or one classification.
#[derive(Clone)]
pub struct Chosen {
    pub provider: String,
    /// The protocol, and the id sent to the API.
    pub tag: ModelTag,
    pub window: u32,
    pub max_output: Option<u32>,
    /// Whether it watches videos.
    pub video: bool,
    /// The effort among them.
    pub options: Options,
    pub retries: u32,
    /// How long a core on this model waits idle before it ends.
    pub idle_window: Duration,
    pub caller: Arc<dyn Caller>,
}

/// Where a model call from a VM goes. The service to its VM forwards it there
/// with the provider's key, which never enters the VM.
#[derive(Clone, Debug)]
pub struct Upstream {
    pub provider: String,
    pub protocol: Protocol,
    pub base_url: String,
    pub api_key: Option<String>,
    pub headers: Vec<(String, String)>,
    /// The id sent to the API.
    pub model: String,
    pub window: u32,
    pub max_output: Option<u32>,
    /// How long the provider may keep quiet, before its answer or within it.
    pub idle: Duration,
}

impl Upstream {
    /// `provider/model`, as the configuration names it, and as a call
    /// from a VM does.
    pub fn reference(&self) -> String {
        format!("{}/{}", self.provider, self.model)
    }
}

/// The models what runs in a VM may call: every configured one, and the
/// one background agents run on unless they are started on another.
#[derive(Clone, Debug)]
pub struct Upstreams {
    /// The agents' own, `llm.job`, and how hard it is asked to think.
    pub default: Arc<Upstream>,
    pub effort: Option<String>,
    /// Each by its `provider/model`, the agents' own among them.
    pub all: BTreeMap<String, Arc<Upstream>>,
}

impl Upstreams {
    /// One model and no other.
    pub fn only(upstream: Upstream, effort: Option<&str>) -> Self {
        let default = Arc::new(upstream);
        Self {
            all: BTreeMap::from([(default.reference(), Arc::clone(&default))]),
            default,
            effort: effort.map(str::to_owned),
        }
    }

    /// The model a call names: the agents' own for no name, and for one
    /// that isn't configured, so that a program which knows nothing of
    /// the names here can call a model all the same.
    pub fn named(&self, name: Option<&str>) -> &Arc<Upstream> {
        name.and_then(|name| self.all.get(name))
            .unwrap_or(&self.default)
    }
}

impl Chosen {
    /// `provider/model`, as `/model` takes it.
    pub fn reference(&self) -> String {
        format!("{}/{}", self.provider, self.tag.model)
    }

    /// A whole answer, for work outside a turn: what the model wrote, its
    /// usage recorded as `purpose`'s. Given up after `limit`; not retried.
    pub async fn complete(
        &self,
        pool: &PgPool,
        purpose: usage::Purpose,
        conversation: Option<ConversationId>,
        request: &Request,
        pictures: &Pictures,
        limit: Duration,
    ) -> Result<String> {
        let (out, timing) = tokio::time::timeout(limit, async {
            let mut call = self.caller.call(request, &self.options, pictures).await?;
            while call.next().await?.is_some() {}
            let timing = call.timing();
            Ok::<_, max_llm::Error>((call.finish()?, timing))
        })
        .await
        .map_err(|_| eyre!("no answer in {limit:?}"))??;
        let call = self.usage(purpose, conversation, None, out.usage, Some(timing));
        record(pool, &call).await;
        Ok(out
            .items
            .iter()
            .filter_map(|item| match &item.kind {
                ItemKind::Assistant { text } => Some(text.as_str()),
                _ => None,
            })
            .collect())
    }

    /// A call of this model's, for `llm_usage`.
    pub fn usage(
        &self,
        purpose: usage::Purpose,
        conversation: Option<ConversationId>,
        turn: Option<TurnId>,
        usage: Usage,
        timing: Option<Timing>,
    ) -> usage::Call<'_> {
        usage::Call {
            conversation,
            turn,
            purpose,
            provider: &self.provider,
            model: &self.tag.model,
            effort: self.options.effort.as_deref(),
            usage,
            cost_micros: None,
            timing,
            at: Utc::now(),
        }
    }
}

impl Models {
    /// Reads each provider's key and makes its client.
    pub fn new(llm: &config::Llm) -> Result<Self> {
        Self::with_callers(llm, |name, provider| {
            let client = max_llm::Client::new(max_llm::Provider {
                base_url: provider.base_url.clone(),
                api_key: provider.api_key()?,
                headers: provider
                    .headers
                    .iter()
                    .map(|(name, value)| (name.clone(), value.clone()))
                    .collect(),
                idle_timeout: Duration::from_secs(provider.stream_idle_timeout_secs),
            })
            .wrap_err_with(|| format!("the client for provider {name}"))?;
            Ok(Arc::new(client))
        })
    }

    pub fn with_callers(
        llm: &config::Llm,
        caller: impl Fn(&str, &config::Provider) -> Result<Arc<dyn Caller>>,
    ) -> Result<Self> {
        let callers = llm
            .providers
            .iter()
            .map(|(name, provider)| Ok((name.clone(), caller(name, provider)?)))
            .collect::<Result<_>>()?;
        Ok(Self {
            llm: llm.clone(),
            callers,
        })
    }

    /// What a turn uses: the conversation's choices where it made them,
    /// the defaults elsewhere.
    pub fn turn(&self, model: Option<&str>, effort: Option<&str>) -> Result<Chosen> {
        let default = &self.llm.default;
        let reference = model.unwrap_or(&default.model);
        self.choose(reference, effort.or(default.effort.as_deref()))
    }

    pub fn intent(&self) -> Result<Chosen> {
        let intent = &self.llm.intent;
        self.choose(&intent.model, intent.effort.as_deref())
    }

    /// The caption worker's model, when one is configured.
    pub fn caption(&self) -> Option<Result<Chosen>> {
        let caption = self.llm.caption.as_ref()?;
        Some(self.choose(&caption.model, caption.effort.as_deref()))
    }

    /// The dreamer's model, when one is configured.
    pub fn dreamer(&self) -> Option<Result<Chosen>> {
        let dreamer = self.llm.dreamer.as_ref()?;
        Some(self.choose(&dreamer.model, dreamer.effort.as_deref()))
    }

    /// Where model calls from the VMs go, when background agents have a
    /// model: to any configured one, and to theirs unless another is
    /// named. Reads the providers' keys.
    pub fn job(&self) -> Option<Result<Upstreams>> {
        let job = self.llm.job.as_ref()?;
        Some(self.upstreams(job))
    }

    fn upstreams(&self, job: &config::Selection) -> Result<Upstreams> {
        let mut all = BTreeMap::new();
        for (name, provider) in &self.llm.providers {
            let api_key = provider.api_key()?;
            for (model, settings) in &provider.models {
                let upstream = Upstream {
                    provider: name.clone(),
                    protocol: provider.protocol.into(),
                    base_url: provider.base_url.clone(),
                    api_key: api_key.clone(),
                    headers: provider
                        .headers
                        .iter()
                        .map(|(name, value)| (name.clone(), value.clone()))
                        .collect(),
                    model: model.clone(),
                    window: settings.context_window,
                    max_output: settings.max_output,
                    idle: Duration::from_secs(provider.stream_idle_timeout_secs),
                };
                all.insert(upstream.reference(), Arc::new(upstream));
            }
        }
        let default = all
            .get(&job.model)
            .ok_or_else(|| eyre!("llm.job names no configured model: {:?}", job.model))?;
        Ok(Upstreams {
            default: Arc::clone(default),
            effort: job.effort.clone(),
            all,
        })
    }

    /// The list price of `provider`'s `model`, as `llm_usage` names them,
    /// if it is configured and has one.
    pub fn price(&self, provider: &str, model: &str) -> Option<config::Price> {
        self.llm.providers.get(provider)?.models.get(model)?.price
    }

    /// How long a core on `model` waits idle before it ends: its
    /// provider's window, or the default model's when it is None or no
    /// longer configured.
    pub fn idle_window(&self, model: Option<&str>) -> Duration {
        let window = |reference: &str| {
            let (_, provider, _, _) = self.llm.model(reference).ok()?;
            Some(provider.idle_window_secs)
        };
        let secs = model
            .and_then(window)
            .or_else(|| window(&self.llm.default.model))
            .unwrap_or(config::IDLE_WINDOW_SECS);
        Duration::from_secs(secs)
    }

    /// Every `provider/model`, for `/model` to list.
    pub fn references(&self) -> Vec<String> {
        self.llm
            .providers
            .iter()
            .flat_map(|(name, provider)| {
                provider
                    .models
                    .keys()
                    .map(move |model| format!("{name}/{model}"))
            })
            .collect()
    }

    pub fn choose(&self, reference: &str, effort: Option<&str>) -> Result<Chosen> {
        let (name, provider, model, settings) = self.llm.model(reference)?;
        Ok(Chosen {
            provider: name.to_owned(),
            tag: ModelTag {
                protocol: provider.protocol.into(),
                model: model.to_owned(),
            },
            window: settings.context_window,
            max_output: settings.max_output,
            video: settings.video,
            options: Options {
                effort: effort.map(str::to_owned),
                temperature: settings.temperature,
                top_p: settings.top_p,
                cache_breakpoints: provider.cache_breakpoints,
            },
            retries: provider.retries,
            idle_window: Duration::from_secs(provider.idle_window_secs),
            caller: Arc::clone(&self.callers[name]),
        })
    }
}

/// Records a model call's usage. What the call gave is used whether or
/// not its record goes in: one that doesn't is logged and let be, for a
/// turn, a job and work outside a turn alike.
pub async fn record(pool: &PgPool, call: &usage::Call<'_>) {
    let recorded = async {
        let mut conn = pool.acquire().await?;
        usage::record(&mut conn, call).await
    };
    if let Err(error) = recorded.await {
        warn!(purpose = ?call.purpose, %error, "couldn't record a model call's usage");
    }
}

#[cfg(test)]
pub mod testing {
    //! A provider that answers from a script, in the Chat protocol.

    use std::collections::VecDeque;
    use std::sync::Mutex;

    use serde_json::json;

    use super::*;

    /// One scripted answer.
    pub enum Answer {
        /// The model writes this, in these pieces.
        Says(Vec<String>),
        /// The model writes this, then the stream ends unfinished.
        Breaks(Vec<String>),
        /// The model calls a tool: its name and arguments.
        Calls(String, String),
        /// The call fails before anything streams.
        Fails(max_llm::Error),
        /// The response never starts.
        Hangs,
    }

    impl Answer {
        pub fn says(text: &str) -> Self {
            Self::Says(vec![text.to_owned()])
        }
    }

    /// Answers calls in order and keeps the requests it was sent, and
    /// the handles of the pictures each came with.
    #[derive(Default)]
    pub struct Script {
        answers: Mutex<VecDeque<Answer>>,
        pub requests: Mutex<Vec<Request>>,
        pub pictures: Mutex<Vec<Vec<String>>>,
    }

    impl Script {
        pub fn push(&self, answer: Answer) {
            self.answers.lock().unwrap().push_back(answer);
        }

        pub fn calls(&self) -> usize {
            self.requests.lock().unwrap().len()
        }
    }

    impl Caller for Script {
        fn call<'a>(
            &'a self,
            request: &'a Request,
            _: &'a Options,
            pictures: &'a Pictures,
        ) -> Pin<Box<dyn Future<Output = Result<Call, max_llm::Error>> + Send + 'a>> {
            let handles = pictures.0.keys().cloned().collect();
            self.pictures.lock().unwrap().push(handles);
            self.requests.lock().unwrap().push(Request {
                model: request.model.clone(),
                items: request.items.clone(),
                tools: request.tools,
                max_output: request.max_output,
                roster: request.roster.clone(),
            });
            let answer = self.answers.lock().unwrap().pop_front();
            let model = request.model.clone();
            Box::pin(async move {
                match answer {
                    Some(Answer::Says(pieces)) => {
                        Ok(Call::replay(model, chat_stream(&pieces, true)))
                    }
                    Some(Answer::Breaks(pieces)) => {
                        Ok(Call::replay(model, chat_stream(&pieces, false)))
                    }
                    Some(Answer::Calls(name, arguments)) => {
                        Ok(Call::replay(model, tool_call_stream(&name, &arguments)))
                    }
                    Some(Answer::Fails(error)) => Err(error),
                    Some(Answer::Hangs) => std::future::pending().await,
                    None => Err(max_llm::Error::Malformed("the script ran out".into())),
                }
            })
        }
    }

    /// A Chat completion stream that writes `pieces` one chunk each, and
    /// finishes if `complete`.
    pub fn chat_stream(pieces: &[String], complete: bool) -> Vec<u8> {
        let mut out = String::new();
        let chunk = |delta: serde_json::Value, finish: Option<&str>, usage| {
            json!({
                "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
                "usage": usage,
            })
        };
        for piece in pieces {
            let data = chunk(json!({"content": piece}), None, serde_json::Value::Null);
            out += &format!("data: {data}\n\n");
        }
        if complete {
            let usage = json!({"prompt_tokens": 1000, "completion_tokens": 10});
            let data = chunk(json!({}), Some("stop"), usage);
            out += &format!("data: {data}\n\ndata: [DONE]\n\n");
        }
        out.into_bytes()
    }

    /// A Chat completion stream that calls one tool.
    pub fn tool_call_stream(name: &str, arguments: &str) -> Vec<u8> {
        let call = json!({"tool_calls": [{
            "index": 0, "id": "call_1", "type": "function",
            "function": {"name": name, "arguments": arguments},
        }]});
        let usage = json!({"prompt_tokens": 1000, "completion_tokens": 10});
        let chunks = [
            json!({"choices": [{"index": 0, "delta": call, "finish_reason": null}]}),
            json!({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}], "usage": usage}),
        ];
        let mut out = String::new();
        for chunk in chunks {
            out += &format!("data: {chunk}\n\n");
        }
        out += "data: [DONE]\n\n";
        out.into_bytes()
    }

    /// `[llm]` with one Chat provider, `test`, and two models.
    pub fn config() -> config::Llm {
        let text = r#"
            default = { model = "test/big", effort = "high" }
            intent = { model = "test/small" }
            [providers.test]
            base_url = "http://127.0.0.1:9/v1"
            protocol = "chat"
            idle_window_secs = 300
            [providers.test.models.big]
            context_window = 100000
            max_output = 8000
            price = { input = 0.5, cached = 0.05, output = 3 }
            [providers.test.models.small]
            context_window = 8000
            # Another the turns may switch to, with room for the prompt.
            [providers.test.models.wide]
            context_window = 200000
        "#;
        toml::from_str(text).unwrap()
    }

    pub fn models(script: &Arc<Script>) -> Models {
        let script = Arc::clone(script);
        Models::with_callers(&config(), move |_, _| Ok(script.clone() as Arc<dyn Caller>)).unwrap()
    }
}

#[cfg(test)]
mod tests {
    use max_core::item::Protocol;

    use super::testing::{Script, models};
    use super::*;

    #[test]
    fn choices_fall_back_to_the_defaults() {
        let models = models(&Arc::new(Script::default()));
        let chosen = models.turn(None, None).unwrap();
        assert_eq!(chosen.reference(), "test/big");
        assert_eq!(chosen.options.effort.as_deref(), Some("high"));
        assert_eq!((chosen.window, chosen.max_output), (100_000, Some(8000)));
        assert_eq!(chosen.tag.protocol, Protocol::Chat);
        let chosen = models.turn(Some("test/small"), Some("low")).unwrap();
        assert_eq!(chosen.reference(), "test/small");
        assert_eq!(chosen.options.effort.as_deref(), Some("low"));
        assert_eq!(models.intent().unwrap().options.effort, None);
        assert!(models.turn(Some("test/nope"), None).is_err());
        assert!(models.turn(Some("big"), None).is_err());
        assert_eq!(models.references(), ["test/big", "test/small", "test/wide"]);
    }

    /// What runs in a VM may call any configured model, and calls the
    /// agents' own unless it names another.
    #[test]
    fn a_vm_calls_any_model_and_the_agents_own_by_default() {
        let script = Arc::new(Script::default());
        let mut llm = testing::config();
        // No model for the agents, no model to call.
        let none = Models::with_callers(&llm, |_, _| Ok(script.clone() as Arc<dyn Caller>));
        assert!(none.unwrap().job().is_none());

        llm.job = Some(config::Selection {
            model: "test/small".into(),
            effort: Some("low".into()),
        });
        let models = Models::with_callers(&llm, |_, _| Ok(script.clone() as Arc<dyn Caller>));
        let upstreams = models.unwrap().job().unwrap().unwrap();
        assert_eq!(upstreams.default.reference(), "test/small");
        assert_eq!(upstreams.effort.as_deref(), Some("low"));
        let names: Vec<_> = upstreams.all.keys().collect();
        assert_eq!(names, ["test/big", "test/small", "test/wide"]);
        let named = |name| upstreams.named(name).reference();
        assert_eq!(named(Some("test/wide")), "test/wide");
        assert_eq!(upstreams.named(Some("test/big")).max_output, Some(8000));
        // No name, the id without its provider, or a stranger's.
        for name in [None, Some("big"), Some("gpt-4o")] {
            assert_eq!(named(name), "test/small");
        }
    }
}
