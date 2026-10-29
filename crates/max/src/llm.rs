//! The models Max can call, built from `[llm]`: a client per provider, the
//! models under it, and the selections. A [`Chosen`] model is all a call
//! needs; the conversation actor picks one when a core starts, and keeps it
//! for the turn.

use std::collections::BTreeMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;

use color_eyre::eyre::{Result, WrapErr};
use max_core::item::{ModelTag, Protocol};
use max_core::run::Request;
use max_llm::{Call, Options, Pictures};

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
    /// The effort among them.
    pub options: Options,
    pub retries: u32,
    /// How long a core on this model waits idle before it ends.
    pub idle_window: Duration,
    pub caller: Arc<dyn Caller>,
}

/// Where a background agent's model calls go. The MCP service forwards
/// them there with the provider's key, which never enters the VM.
#[derive(Clone, Debug)]
pub struct Upstream {
    pub provider: String,
    pub protocol: Protocol,
    pub base_url: String,
    pub api_key: Option<String>,
    pub headers: Vec<(String, String)>,
    /// The id sent to the API, whatever the agent asks for.
    pub model: String,
    pub window: u32,
    pub max_output: Option<u32>,
    pub effort: Option<String>,
    /// How long the provider may keep quiet, before its answer or within it.
    pub idle: Duration,
}

impl Upstream {
    /// `provider/model`, as the configuration names it.
    pub fn reference(&self) -> String {
        format!("{}/{}", self.provider, self.model)
    }
}

impl Chosen {
    /// `provider/model`, as `/model` takes it.
    pub fn reference(&self) -> String {
        format!("{}/{}", self.provider, self.tag.model)
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

    /// The historian's model, when one is configured.
    pub fn historian(&self) -> Option<Result<Chosen>> {
        let historian = self.llm.historian.as_ref()?;
        Some(self.choose(&historian.model, historian.effort.as_deref()))
    }

    /// The caption worker's model, when one is configured.
    pub fn caption(&self) -> Option<Result<Chosen>> {
        let caption = self.llm.caption.as_ref()?;
        Some(self.choose(&caption.model, caption.effort.as_deref()))
    }

    /// Where background agents' model calls go, when a model is
    /// configured for them. Reads the provider's key.
    pub fn job(&self) -> Option<Result<Upstream>> {
        let job = self.llm.job.as_ref()?;
        Some(self.upstream(&job.model, job.effort.as_deref()))
    }

    fn upstream(&self, reference: &str, effort: Option<&str>) -> Result<Upstream> {
        let (name, provider, model, settings) = self.llm.model(reference)?;
        Ok(Upstream {
            provider: name.to_owned(),
            protocol: provider.protocol.into(),
            base_url: provider.base_url.clone(),
            api_key: provider.api_key()?,
            headers: provider
                .headers
                .iter()
                .map(|(name, value)| (name.clone(), value.clone()))
                .collect(),
            model: model.to_owned(),
            window: settings.context_window,
            max_output: settings.max_output,
            effort: effort.map(str::to_owned),
            idle: Duration::from_secs(provider.stream_idle_timeout_secs),
        })
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
            historian = { model = "test/big", effort = "low" }
            [providers.test]
            base_url = "http://127.0.0.1:9/v1"
            protocol = "chat"
            idle_window_secs = 300
            [providers.test.models.big]
            context_window = 100000
            max_output = 8000
            [providers.test.models.small]
            context_window = 8000
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
        let historian = models.historian().unwrap().unwrap();
        assert_eq!(historian.options.effort.as_deref(), Some("low"));
        assert!(models.turn(Some("test/nope"), None).is_err());
        assert!(models.turn(Some("big"), None).is_err());
        assert_eq!(models.references(), ["test/big", "test/small"]);
    }
}
