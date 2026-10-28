use std::time::Duration;

/// Why a model call failed. Whether to try again is [`Error::retryable`];
/// the caller decides whether it may, since text already said can't be
/// taken back.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("couldn't reach the provider: {0}")]
    Connect(#[source] reqwest::Error),
    #[error("the provider answered {status}: {body}")]
    Status { status: u16, body: String },
    #[error("nothing from the provider for {0:?}")]
    Idle(Duration),
    /// The connection broke while the response was streaming.
    #[error("the response broke off: {0}")]
    Body(String),
    /// The stream ended cleanly but without its final event.
    #[error("the response ended before it was complete")]
    Truncated,
    /// The provider reported a failure inside the stream.
    #[error("the provider failed the response: {code}: {message}")]
    Provider { code: String, message: String },
    /// The model stopped before finishing, such as at the output limit.
    #[error("the response stopped early: {0}")]
    Incomplete(String),
    #[error("unexpected data from the provider: {0}")]
    Malformed(String),
}

impl Error {
    /// Whether the same request might succeed if sent again.
    pub fn retryable(&self) -> bool {
        match self {
            Self::Connect(_) | Self::Idle(_) | Self::Body(_) | Self::Truncated => true,
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

    pub(crate) fn malformed(error: impl std::fmt::Display) -> Self {
        Self::Malformed(error.to_string())
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
        assert!(status(429).retryable());
        assert!(status(503).retryable());
        assert!(!status(400).retryable());
        assert!(!status(401).retryable());
        assert!(Error::Truncated.retryable());
        assert!(!Error::Incomplete("max_output_tokens".into()).retryable());

        let overloaded = Error::provider(&json!({ "code": "server_error", "message": "busy" }));
        assert!(overloaded.retryable());
        let wrapped = json!({ "error": { "type": "rate_limit_error", "message": "slow down" } });
        assert!(Error::provider(&wrapped).retryable());
        let too_long =
            Error::provider(&json!({ "code": "context_length_exceeded", "message": "" }));
        assert!(!too_long.retryable());
        assert_eq!(
            too_long.to_string(),
            "the provider failed the response: context_length_exceeded: "
        );
    }
}
