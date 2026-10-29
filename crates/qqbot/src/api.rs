//! The REST side: access tokens, and the calls Max makes.

use std::fmt;
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use reqwest::{Method, StatusCode};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize};
use tokio::sync::Mutex;

use crate::message::{Outgoing, Sent};

/// Where the API has been since 2026-08-10. The old api.sgroup.qq.com
/// still answers.
pub const API_BASE: &str = "https://api.bot.qq.com";
pub const TOKEN_URL: &str = "https://bots.qq.com/app/getAppAccessToken";

/// How long before a token expires a new one is fetched. QQ hands out a
/// new token only in the last 60 seconds of the old one, which then stays
/// valid for 60 seconds more.
const REFRESH_BEFORE: Duration = Duration::from_secs(50);

const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
/// Between reads, not for the whole call.
const READ_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Clone)]
pub struct Credentials {
    pub app_id: String,
    pub secret: String,
}

impl fmt::Debug for Credentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Credentials")
            .field("app_id", &self.app_id)
            .finish_non_exhaustive()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("request to QQ failed: {0}")]
    Http(#[from] reqwest::Error),
    /// QQ answered with an error.
    #[error("QQ answered {status} to {path}: {code} {message} (trace {trace})")]
    Api {
        path: String,
        status: u16,
        /// `err_code`, or `code` when that is all there is.
        code: i64,
        message: String,
        trace: String,
    },
    #[error("unexpected answer from QQ to {path}: {source}")]
    Decode {
        path: String,
        source: serde_json::Error,
    },
}

impl Error {
    /// QQ's error code, if it answered.
    pub fn code(&self) -> Option<i64> {
        match self {
            Self::Api { code, .. } => Some(*code),
            _ => None,
        }
    }
}

/// A chat to send to: a group by its `group_openid`, or a person in a
/// private chat by their `user_openid`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Chat<'a> {
    Group(&'a str),
    User(&'a str),
}

impl Chat<'_> {
    fn messages(self) -> String {
        match self {
            Self::Group(group) => format!("/v2/groups/{group}/messages"),
            Self::User(user) => format!("/v2/users/{user}/messages"),
        }
    }

    fn files(self) -> String {
        match self {
            Self::Group(group) => format!("/v2/groups/{group}/files"),
            Self::User(user) => format!("/v2/users/{user}/files"),
        }
    }
}

/// A picture uploaded to a chat: a message sends its `file_info`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Uploaded {
    pub file_info: String,
    /// Seconds it can still be sent for, a day when tried in 2026-10;
    /// 0 is for good.
    #[serde(default)]
    pub ttl: u64,
}

#[derive(Serialize)]
struct Upload {
    /// 1 is a picture: PNG, JPEG or GIF, which stays animated.
    file_type: u8,
    file_data: String,
    /// Upload only; a message sends it.
    srv_send_msg: bool,
}

/// The bot itself.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Me {
    pub id: String,
    pub username: String,
}

pub struct Client {
    http: reqwest::Client,
    base: String,
    token_url: String,
    credentials: Credentials,
    token: Mutex<Option<Token>>,
}

struct Token {
    value: String,
    refresh_at: Instant,
}

impl Client {
    pub fn new(credentials: Credentials) -> Result<Self, Error> {
        Self::with_urls(credentials, API_BASE, TOKEN_URL)
    }

    pub fn with_urls(
        credentials: Credentials,
        base: impl Into<String>,
        token_url: impl Into<String>,
    ) -> Result<Self, Error> {
        let http = reqwest::Client::builder()
            .connect_timeout(CONNECT_TIMEOUT)
            .read_timeout(READ_TIMEOUT)
            .build()?;
        Ok(Self {
            http,
            base: base.into(),
            token_url: token_url.into(),
            credentials,
            token: Mutex::new(None),
        })
    }

    /// A valid access token, fetched again shortly before it expires.
    pub async fn token(&self) -> Result<String, Error> {
        let mut token = self.token.lock().await;
        if let Some(token) = token.as_ref()
            && Instant::now() < token.refresh_at
        {
            return Ok(token.value.clone());
        }
        let request = TokenRequest {
            app_id: &self.credentials.app_id,
            client_secret: &self.credentials.secret,
        };
        let response = self
            .http
            .post(&self.token_url)
            .json(&request)
            .send()
            .await?;
        let status = response.status();
        let body = response.bytes().await?;
        let fresh: TokenResponse = decode("getAppAccessToken", status, &body)?;
        let lifetime = Duration::from_secs(fresh.expires_in).saturating_sub(REFRESH_BEFORE);
        let value = fresh.access_token;
        *token = Some(Token {
            value: value.clone(),
            refresh_at: Instant::now() + lifetime,
        });
        Ok(value)
    }

    pub async fn me(&self) -> Result<Me, Error> {
        self.call(Method::GET, "/users/@me", None::<&()>).await
    }

    /// The WebSocket gateway's address.
    pub async fn gateway(&self) -> Result<String, Error> {
        #[derive(Deserialize)]
        struct Gateway {
            url: String,
        }
        let gateway: Gateway = self.call(Method::GET, "/gateway", None::<&()>).await?;
        Ok(gateway.url)
    }

    pub async fn send(&self, chat: Chat<'_>, message: &Outgoing) -> Result<Sent, Error> {
        self.call(Method::POST, &chat.messages(), Some(message))
            .await
    }

    /// Uploads a picture to send to `chat`, as many times as it likes
    /// while it lasts.
    pub async fn upload(&self, chat: Chat<'_>, picture: &[u8]) -> Result<Uploaded, Error> {
        let upload = Upload {
            file_type: 1,
            file_data: STANDARD.encode(picture),
            srv_send_msg: false,
        };
        self.call(Method::POST, &chat.files(), Some(&upload)).await
    }

    /// Recalls a message: the bot's own within 2 minutes, or anyone's
    /// when the bot is a group admin.
    pub async fn recall(&self, chat: Chat<'_>, message_id: &str) -> Result<(), Error> {
        let path = format!("{}/{message_id}", chat.messages());
        let _: serde_json::Value = self.call(Method::DELETE, &path, None::<&()>).await?;
        Ok(())
    }

    async fn call<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: Option<&impl Serialize>,
    ) -> Result<T, Error> {
        let token = self.token().await?;
        let mut request = self
            .http
            .request(method, format!("{}{path}", self.base))
            .header("Authorization", format!("QQBot {token}"));
        if let Some(body) = body {
            request = request.json(body);
        }
        let response = request.send().await?;
        let status = response.status();
        let body = response.bytes().await?;
        decode(path, status, &body)
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TokenRequest<'a> {
    app_id: &'a str,
    client_secret: &'a str,
}

#[derive(Deserialize)]
struct TokenResponse {
    access_token: String,
    /// Seconds left, sent as a string.
    #[serde(deserialize_with = "number_or_string")]
    expires_in: u64,
}

fn number_or_string<'de, D: Deserializer<'de>>(deserializer: D) -> Result<u64, D::Error> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum Either {
        Number(u64),
        Text(String),
    }
    match Either::deserialize(deserializer)? {
        Either::Number(n) => Ok(n),
        Either::Text(text) => text.parse().map_err(serde::de::Error::custom),
    }
}

#[derive(Deserialize)]
struct ErrorBody {
    #[serde(default)]
    code: Option<i64>,
    #[serde(default)]
    err_code: Option<i64>,
    #[serde(default)]
    message: String,
    #[serde(default)]
    trace_id: Option<String>,
}

/// Reads an answer. QQ reports some errors with a success status (the
/// token endpoint, and 201 or 202 for some calls), so a body with an error
/// code is an error whatever the status. An empty body reads as `null`.
fn decode<T: DeserializeOwned>(path: &str, status: StatusCode, body: &[u8]) -> Result<T, Error> {
    let body = if body.iter().all(u8::is_ascii_whitespace) {
        b"null".as_slice()
    } else {
        body
    };
    let error = serde_json::from_slice::<ErrorBody>(body).ok();
    let code = error
        .as_ref()
        .and_then(|error| error.err_code.or(error.code))
        .filter(|code| *code != 0);
    if !status.is_success() || code.is_some() {
        let error = error.unwrap_or(ErrorBody {
            code: None,
            err_code: None,
            message: String::from_utf8_lossy(body).into_owned(),
            trace_id: None,
        });
        return Err(Error::Api {
            path: path.to_owned(),
            status: status.as_u16(),
            code: code.unwrap_or_default(),
            message: error.message,
            trace: error.trace_id.unwrap_or_default(),
        });
    }
    serde_json::from_slice(body).map_err(|source| Error::Decode {
        path: path.to_owned(),
        source,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_token() {
        let body = br#"{"access_token":"t0","expires_in":"7200"}"#;
        let token: TokenResponse = decode("token", StatusCode::OK, body).unwrap();
        assert_eq!(
            (token.access_token.as_str(), token.expires_in),
            ("t0", 7200)
        );
        let refused = br#"{"code":100016,"message":"invalid appid"}"#;
        // No Debug on the response: it holds the token.
        let Err(error) = decode::<TokenResponse>("token", StatusCode::OK, refused) else {
            panic!("refused, but read as a token");
        };
        assert_eq!(error.code(), Some(100016));
    }

    #[test]
    fn errors_say_what_qq_said() {
        let body =
            r#"{"message":"请求方法非法","code":10006,"err_code":40011001,"trace_id":"abc"}"#;
        let status = StatusCode::METHOD_NOT_ALLOWED;
        let error = decode::<Me>("/v2/x", status, body.as_bytes()).unwrap_err();
        assert_eq!(
            error.to_string(),
            "QQ answered 405 to /v2/x: 40011001 请求方法非法 (trace abc)"
        );
        let gateway_down = decode::<Me>("/gateway", StatusCode::BAD_GATEWAY, b"<html>");
        assert!(matches!(
            gateway_down,
            Err(Error::Api { status: 502, code: 0, ref message, .. }) if message == "<html>"
        ));
    }

    #[test]
    fn success_bodies() {
        let me: Me = decode(
            "/users/@me",
            StatusCode::OK,
            br#"{"id":"1","username":"maxx","avatar":"a"}"#,
        )
        .unwrap();
        assert_eq!(me.username, "maxx");
        let recalled: serde_json::Value = decode("/x", StatusCode::NO_CONTENT, b"").unwrap();
        assert!(recalled.is_null());
        let odd = decode::<Me>("/users/@me", StatusCode::OK, b"{}").unwrap_err();
        assert!(matches!(odd, Error::Decode { .. }));
    }

    #[test]
    fn paths() {
        assert_eq!(Chat::Group("G1").messages(), "/v2/groups/G1/messages");
        assert_eq!(Chat::User("U1").messages(), "/v2/users/U1/messages");
        assert_eq!(Chat::Group("G1").files(), "/v2/groups/G1/files");
    }

    #[test]
    fn an_upload() {
        // As QQ answered on 2026-10-29.
        let body = br#"{"file_uuid":"u","file_info":"FI","ttl":86400,"id":"","raw_url":""}"#;
        let uploaded: Uploaded = decode("/v2/groups/G1/files", StatusCode::OK, body).unwrap();
        assert_eq!(
            uploaded,
            Uploaded {
                file_info: "FI".into(),
                ttl: 86400
            }
        );
    }

    #[test]
    fn the_secret_stays_out_of_logs() {
        let credentials = Credentials {
            app_id: "1".into(),
            secret: "s3cret".into(),
        };
        assert!(!format!("{credentials:?}").contains("s3cret"));
    }
}
