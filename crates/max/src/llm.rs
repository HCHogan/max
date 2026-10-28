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
use max_llm::{Call, Options};

use crate::config;

/// Starts a model call. A provider's client in service; a script in tests.
pub trait Caller: Send + Sync {
    fn call<'a>(
        &'a self,
        request: &'a Request,
        options: &'a Options,
    ) -> Pin<Box<dyn Future<Output = Result<Call, max_llm::Error>> + Send + 'a>>;
}

impl Caller for max_llm::Client {
    fn call<'a>(
        &'a self,
        request: &'a Request,
        options: &'a Options,
    ) -> Pin<Box<dyn Future<Output = Result<Call, max_llm::Error>> + Send + 'a>> {
        Box::pin(max_llm::Client::call(self, request, options))
    }
}

pub struct Models {
    providers: BTreeMap<String, Provider>,
    default: config::Selection,
    intent: config::Selection,
}

struct Provider {
    caller: Arc<dyn Caller>,
    protocol: Protocol,
    retries: u32,
    idle_window: Duration,
    cache_breakpoints: bool,
    models: BTreeMap<String, config::Model>,
}

/// A model and how to call it, for one turn or one classification.
#[derive(Clone)]
pub struct Chosen {
    pub provider: String,
    /// The id sent to the API.
    pub model: String,
    pub effort: Option<String>,
    pub tag: ModelTag,
    pub window: u32,
    pub max_output: Option<u32>,
    pub options: Options,
    pub retries: u32,
    /// How long a core on this model waits idle before it ends.
    pub idle_window: Duration,
    pub caller: Arc<dyn Caller>,
}

impl Chosen {
    /// `provider/model`, as `!model` takes it.
    pub fn reference(&self) -> String {
        format!("{}/{}", self.provider, self.model)
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
        let providers = llm
            .providers
            .iter()
            .map(|(name, provider)| {
                Ok((
                    name.clone(),
                    Provider {
                        caller: caller(name, provider)?,
                        protocol: provider.protocol.into(),
                        retries: provider.retries,
                        idle_window: Duration::from_secs(provider.idle_window_secs),
                        cache_breakpoints: provider.cache_breakpoints,
                        models: provider.models.clone(),
                    },
                ))
            })
            .collect::<Result<_>>()?;
        Ok(Self {
            providers,
            default: llm.default.clone(),
            intent: llm.intent.clone(),
        })
    }

    /// What a turn uses: the conversation's choices where it made them,
    /// the defaults elsewhere.
    pub fn turn(&self, model: Option<&str>, effort: Option<&str>) -> Result<Chosen> {
        let reference = model.unwrap_or(&self.default.model);
        let effort = effort.or(self.default.effort.as_deref());
        self.choose(reference, effort)
    }

    pub fn intent(&self) -> Result<Chosen> {
        self.choose(&self.intent.model, self.intent.effort.as_deref())
    }

    /// Every `provider/model`, for `!model` to list.
    pub fn references(&self) -> Vec<String> {
        self.providers
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
        let (name, model) = reference
            .split_once('/')
            .ok_or_else(|| color_eyre::eyre::eyre!("{reference:?} isn't provider/model"))?;
        let provider = self
            .providers
            .get(name)
            .ok_or_else(|| color_eyre::eyre::eyre!("no provider {name:?}"))?;
        let settings = provider
            .models
            .get(model)
            .ok_or_else(|| color_eyre::eyre::eyre!("{name:?} has no model {model:?}"))?;
        Ok(Chosen {
            provider: name.to_owned(),
            model: model.to_owned(),
            effort: effort.map(str::to_owned),
            tag: ModelTag {
                protocol: provider.protocol,
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
            idle_window: provider.idle_window,
            caller: Arc::clone(&provider.caller),
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
        /// The call fails before anything streams.
        Fails(max_llm::Error),
    }

    impl Answer {
        pub fn says(text: &str) -> Self {
            Self::Says(vec![text.to_owned()])
        }
    }

    /// Answers calls in order and keeps the requests it was sent.
    #[derive(Default)]
    pub struct Script {
        answers: Mutex<VecDeque<Answer>>,
        pub requests: Mutex<Vec<Request>>,
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
        ) -> Pin<Box<dyn Future<Output = Result<Call, max_llm::Error>> + Send + 'a>> {
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
                    Some(Answer::Says(pieces)) => Ok(Call::replay(model, chat_stream(&pieces))),
                    Some(Answer::Fails(error)) => Err(error),
                    None => Err(max_llm::Error::Malformed("the script ran out".into())),
                }
            })
        }
    }

    /// A Chat completion stream that writes `pieces` one chunk each.
    pub fn chat_stream(pieces: &[String]) -> Vec<u8> {
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
        let usage = json!({"prompt_tokens": 1000, "completion_tokens": 10});
        let data = chunk(json!({}), Some("stop"), usage);
        out += &format!("data: {data}\n\ndata: [DONE]\n\n");
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
    use super::testing::{Script, models};
    use super::*;

    #[test]
    fn choices_fall_back_to_the_defaults() {
        let models = models(&Arc::new(Script::default()));
        let chosen = models.turn(None, None).unwrap();
        assert_eq!(chosen.reference(), "test/big");
        assert_eq!(chosen.effort.as_deref(), Some("high"));
        assert_eq!((chosen.window, chosen.max_output), (100_000, Some(8000)));
        assert_eq!(chosen.tag.protocol, Protocol::Chat);
        let chosen = models.turn(Some("test/small"), Some("low")).unwrap();
        assert_eq!(chosen.reference(), "test/small");
        assert_eq!(chosen.options.effort.as_deref(), Some("low"));
        assert_eq!(models.intent().unwrap().effort, None);
        assert!(models.turn(Some("test/nope"), None).is_err());
        assert!(models.turn(Some("big"), None).is_err());
        assert_eq!(models.references(), ["test/big", "test/small"]);
    }
}
