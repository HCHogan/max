use std::time::Duration;

/// What a failure came of, where something under it says: an error's
/// source.
pub type Cause = Box<dyn std::error::Error + Send + Sync>;

/// Why a model call failed. Whether to try again is [`Error::is_retryable`];
/// the caller decides whether it may, since text already said can't be
/// taken back.
///
/// A variant says what happened, and its source what that came of: the
/// two are said together by whoever prints the chain, and neither twice.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// The request didn't get there, or no response began.
    #[error("couldn't reach the provider")]
    Connect(#[source] reqwest::Error),
    /// The provider answered with an error's status.
    #[error("the provider answered {status}: {body}")]
    Status {
        status: u16,
        /// The start of what it said.
        body: String,
    },
    /// Nothing arrived for the provider's idle timeout, which this is.
    #[error("nothing from the provider for {0:?}")]
    Idle(Duration),
    /// The connection broke while the response was streaming.
    #[error("the response broke off")]
    Body(#[source] Cause),
    /// The stream ended cleanly but without its final event.
    #[error("the response ended before it was complete")]
    Truncated,
    /// The provider reported a failure inside the stream.
    #[error("the provider failed the response: {code}: {message}")]
    Provider {
        /// Its code for the failure, or its type where it gives no code.
        code: String,
        message: String,
    },
    /// The model stopped before finishing, such as at the output limit.
    #[error("the response stopped early: {0}")]
    Incomplete(String),
    /// What came isn't what the protocol says comes.
    #[error("unexpected data from the provider")]
    Malformed(#[source] Cause),
    /// The model wrote its reasoning as its answer, under a heading such
    /// as `Thinking Process:`, instead of thinking first. Nothing of it was
    /// said.
    #[error("the model wrote its reasoning as its answer")]
    Aloud,
}

impl Error {
    /// Whether the same request might succeed if sent again.
    #[must_use]
    pub fn is_retryable(&self) -> bool {
        match self {
            Self::Connect(_) | Self::Idle(_) | Self::Body(_) | Self::Truncated | Self::Aloud => {
                true
            }
            Self::Status { status, .. } => matches!(status, 408 | 409 | 425 | 429 | 500..=599),
            Self::Provider { code, .. } => [
                "server_error",
                "rate_limit",
                "overloaded",
                "unavailable",
                "timeout",
            ]
            .iter()
            .any(|transient| code.contains(transient)),
            Self::Incomplete(_) | Self::Malformed(_) => false,
        }
    }

    pub(crate) fn malformed(cause: impl Into<Cause>) -> Self {
        Self::Malformed(cause.into())
    }

    /// From an error object as providers send it, inside a stream or as a
    /// response body: `{code, message}`, possibly wrapped in `error`.
    pub(crate) fn provider(error: &serde_json::Value) -> Self {
        let error = error
            .get("error")
            .filter(|e| e.is_object())
            .unwrap_or(error);
        let field = |name: &str| match &error[name] {
            serde_json::Value::String(text) => text.clone(),
            serde_json::Value::Null => String::new(),
            other => other.to_string(),
        };
        let code = Some(field("code"))
            .filter(|code| !code.is_empty())
            .unwrap_or_else(|| field("type"));
        Self::Provider {
            code,
            message: field("message"),
        }
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn what_is_worth_retrying() {
        let status = |status| Error::Status {
            status,
            body: String::new(),
        };
        assert!(status(429).is_retryable());
        assert!(status(503).is_retryable());
        assert!(!status(400).is_retryable());
        assert!(!status(401).is_retryable());
        assert!(Error::Truncated.is_retryable());
        assert!(!Error::Incomplete("max_output_tokens".into()).is_retryable());

        let overloaded = Error::provider(&json!({ "code": "server_error", "message": "busy" }));
        assert!(overloaded.is_retryable());
        let wrapped = json!({ "error": { "type": "rate_limit_error", "message": "slow down" } });
        assert!(Error::provider(&wrapped).is_retryable());
        let too_long =
            Error::provider(&json!({ "code": "context_length_exceeded", "message": "" }));
        assert!(!too_long.is_retryable());
        assert_eq!(
            too_long.to_string(),
            "the provider failed the response: context_length_exceeded: "
        );
    }
}
