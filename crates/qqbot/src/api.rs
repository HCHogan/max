//! The REST side: access tokens, and the calls Max makes.

use std::fmt;
use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use md5::{Digest, Md5};
use reqwest::{Method, StatusCode};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize};
use sha1::Sha1;
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

/// The most uploaded in one request, base64 in the JSON; more goes in
/// parts. Tried on 2026-10-29: 6 MiB went in one, 8 MiB didn't (850012).
const AT_ONCE: usize = 5 << 20;
/// How much of a file `md5_10m` is the MD5 of.
const MD5_10M: usize = 10_002_432;

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
    #[error("QQ's parts for an upload don't fit the file: {0}")]
    Parts(String),
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
    /// `messages`, `files`, … under the chat.
    fn path(self, what: &str) -> String {
        match self {
            Self::Group(group) => format!("/v2/groups/{group}/{what}"),
            Self::User(user) => format!("/v2/users/{user}/{what}"),
        }
    }
}

/// What is uploaded to a chat.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Media<'a> {
    /// PNG, JPEG or GIF, which stays animated.
    Picture(&'a [u8]),
    /// Anything, shown and saved under its name.
    File { name: &'a str, bytes: &'a [u8] },
}

impl<'a> Media<'a> {
    fn file_type(self) -> u8 {
        match self {
            Self::Picture(_) => 1,
            Self::File { .. } => 4,
        }
    }

    fn bytes(self) -> &'a [u8] {
        match self {
            Self::Picture(bytes) | Self::File { bytes, .. } => bytes,
        }
    }

    /// A picture's isn't shown, but the upload in parts asks for one.
    fn name(self) -> &'a str {
        match self {
            Self::Picture(_) => "picture",
            Self::File { name, .. } => name,
        }
    }
}

/// A picture or file uploaded to a chat: a message sends its `file_info`.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Uploaded {
    pub file_info: String,
    /// Seconds it can still be sent for, a day when tried in 2026-10;
    /// 0 is for good.
    #[serde(default)]
    pub ttl: u64,
}

#[derive(Serialize)]
struct Upload<'a> {
    file_type: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_name: Option<&'a str>,
    file_data: String,
    /// Upload only; a message sends it.
    srv_send_msg: bool,
}

/// The upload in parts, as tried on 2026-10-29: `upload_prepare` fails
/// without the digests.
#[derive(Serialize)]
struct Prepare<'a> {
    file_type: u8,
    file_name: &'a str,
    file_size: u64,
    md5: String,
    sha1: String,
    md5_10m: String,
}

#[derive(Deserialize)]
struct Prepared {
    upload_id: String,
    /// Every part's but the last; sent as a string.
    #[serde(deserialize_with = "number_or_string")]
    block_size: u64,
    parts: Vec<Part>,
}

#[derive(Deserialize)]
struct Part {
    /// From 1.
    index: u64,
    presigned_url: String,
    #[serde(deserialize_with = "number_or_string")]
    block_size: u64,
}

/// A part is put where it was told, then reported.
#[derive(Serialize)]
struct PartDone<'a> {
    upload_id: &'a str,
    part_index: u64,
    block_size: u64,
    md5: String,
}

/// Every part is in: QQ puts them together.
#[derive(Serialize)]
struct Merge<'a> {
    upload_id: &'a str,
    file_type: u8,
    file_name: &'a str,
    srv_send_msg: bool,
}

/// A change to someone's mute in a group, which only a group admin may
/// make: add and update only for normal members.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Mute<'a> {
    pub op: MuteOp,
    pub member_openid: &'a str,
    /// Until when, in RFC 3339 as QQ shows it (`+08:00`); empty for `Del`,
    /// which lifts the mute at once.
    pub mute_expire_at: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MuteOp {
    Add,
    /// A new end for a mute that runs.
    Update,
    Del,
}

/// Someone muted in a group now.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Muted {
    pub member_openid: String,
    pub mute_expire_at: String,
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
        self.call(Method::POST, &chat.path("messages"), Some(message))
            .await
    }

    /// Uploads a picture or file to send to `chat`, as many times as it
    /// likes while it lasts: in one request up to 5 MiB, in parts past it.
    pub async fn upload(&self, chat: Chat<'_>, media: Media<'_>) -> Result<Uploaded, Error> {
        if media.bytes().len() > AT_ONCE {
            return self.upload_in_parts(chat, media).await;
        }
        let upload = Upload {
            file_type: media.file_type(),
            file_name: matches!(media, Media::File { .. }).then(|| media.name()),
            file_data: STANDARD.encode(media.bytes()),
            srv_send_msg: false,
        };
        self.call(Method::POST, &chat.path("files"), Some(&upload))
            .await
    }

    /// QQ hands out where to put each part, one after another, and puts
    /// them together once all are reported.
    async fn upload_in_parts(&self, chat: Chat<'_>, media: Media<'_>) -> Result<Uploaded, Error> {
        let bytes = media.bytes();
        let prepare = Prepare {
            file_type: media.file_type(),
            file_name: media.name(),
            file_size: bytes.len() as u64,
            md5: hex(&Md5::digest(bytes)),
            sha1: hex(&Sha1::digest(bytes)),
            md5_10m: hex(&Md5::digest(&bytes[..bytes.len().min(MD5_10M)])),
        };
        let prepared: Prepared = self
            .call(Method::POST, &chat.path("upload_prepare"), Some(&prepare))
            .await?;
        for part in &prepared.parts {
            let piece = piece(bytes, prepared.block_size, part)?;
            let response = self
                .http
                .put(&part.presigned_url)
                .header("Content-Type", "application/octet-stream")
                .body(piece.to_vec())
                .send()
                .await?;
            let status = response.status();
            if !status.is_success() {
                return Err(Error::Api {
                    path: format!("part {} of an upload", part.index),
                    status: status.as_u16(),
                    code: 0,
                    message: response.text().await.unwrap_or_default(),
                    trace: String::new(),
                });
            }
            let done = PartDone {
                upload_id: &prepared.upload_id,
                part_index: part.index,
                block_size: part.block_size,
                md5: hex(&Md5::digest(piece)),
            };
            let _: serde_json::Value = self
                .call(Method::POST, &chat.path("upload_part_finish"), Some(&done))
                .await?;
        }
        let merge = Merge {
            upload_id: &prepared.upload_id,
            file_type: media.file_type(),
            file_name: media.name(),
            srv_send_msg: false,
        };
        self.call(Method::POST, &chat.path("files"), Some(&merge))
            .await
    }

    /// Recalls a message: the bot's own within 2 minutes, or anyone's
    /// when the bot is a group admin.
    pub async fn recall(&self, chat: Chat<'_>, message_id: &str) -> Result<(), Error> {
        let path = format!("{}/{message_id}", chat.path("messages"));
        let _: serde_json::Value = self.call(Method::DELETE, &path, None::<&()>).await?;
        Ok(())
    }

    /// The members muted in a group now, besides any mute of the whole
    /// group. Only for a group admin.
    pub async fn muted(&self, group: &str) -> Result<Vec<Muted>, Error> {
        #[derive(Deserialize)]
        struct Setting {
            #[serde(default)]
            members: Vec<Muted>,
        }
        let path = format!("/v2/groups/{group}/restrict_chat_setting");
        let setting: Setting = self.call(Method::GET, &path, None::<&()>).await?;
        Ok(setting.members)
    }

    /// Mutes someone in a group, changes until when, or lifts it; at most
    /// 30 days. Only for a group admin.
    pub async fn mute(&self, group: &str, mute: &Mute<'_>) -> Result<(), Error> {
        #[derive(Serialize)]
        struct Change<'a, 'b> {
            members: [&'a Mute<'b>; 1],
        }
        let path = format!("/v2/groups/{group}/restrict_chat_setting");
        let change = Change { members: [mute] };
        let _: serde_json::Value = self.call(Method::POST, &path, Some(&change)).await?;
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

/// The bytes of `part`, if they are within the file.
fn piece<'a>(bytes: &'a [u8], block_size: u64, part: &Part) -> Result<&'a [u8], Error> {
    let start = part
        .index
        .checked_sub(1)
        .and_then(|before| before.checked_mul(block_size));
    let end = start.and_then(|start| start.checked_add(part.block_size));
    match (start, end) {
        (Some(start), Some(end)) if start < end && end <= bytes.len() as u64 => {
            Ok(&bytes[start as usize..end as usize])
        }
        _ => Err(Error::Parts(format!(
            "part {} of {} bytes, each {block_size}, in {}",
            part.index,
            part.block_size,
            bytes.len()
        ))),
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
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
        assert_eq!(Chat::Group("G1").path("messages"), "/v2/groups/G1/messages");
        assert_eq!(Chat::User("U1").path("files"), "/v2/users/U1/files");
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
    fn uploads_at_once() {
        let picture = Upload {
            file_type: Media::Picture(b"").file_type(),
            file_name: None,
            file_data: "AA==".into(),
            srv_send_msg: false,
        };
        assert_eq!(
            serde_json::to_value(&picture).unwrap(),
            serde_json::json!({ "file_type": 1, "file_data": "AA==", "srv_send_msg": false })
        );
        let file = Media::File {
            name: "报告.pdf",
            bytes: b"",
        };
        assert_eq!((file.file_type(), file.name()), (4, "报告.pdf"));
    }

    #[test]
    fn uploads_in_parts() {
        assert_eq!(hex(&Md5::digest(b"")), "d41d8cd98f00b204e9800998ecf8427e");
        assert_eq!(
            hex(&Sha1::digest(b"abc")),
            "a9993e364706816aba3e25717850c26c9cd0d89d"
        );
        // As QQ answered on 2026-10-29, for a file of 12 MiB.
        let body = br#"{"upload_id":"U1","block_size":"10485760","parts":[
            {"index":1,"presigned_url":"https://cos/1","block_size":"10485760"},
            {"index":2,"presigned_url":"https://cos/2","block_size":"2097152"}],
            "upload_config":{"concurrency":1,"retry_timeout":300,"retry_delay":1}}"#;
        let prepared: Prepared =
            decode("/v2/groups/G1/upload_prepare", StatusCode::OK, body).unwrap();
        let file = vec![7u8; 12 << 20];
        let pieces: Vec<usize> = prepared
            .parts
            .iter()
            .map(|part| piece(&file, prepared.block_size, part).unwrap().len())
            .collect();
        assert_eq!(pieces, [10 << 20, 2 << 20]);
        let past = Part {
            index: 3,
            presigned_url: String::new(),
            block_size: 1,
        };
        assert!(matches!(
            piece(&file, prepared.block_size, &past),
            Err(Error::Parts(_))
        ));
        let zeroth = Part { index: 0, ..past };
        assert!(piece(&file, prepared.block_size, &zeroth).is_err());
    }

    #[test]
    fn mutes() {
        let mute = Mute {
            op: MuteOp::Add,
            member_openid: "M1",
            mute_expire_at: "2026-10-29T15:29:37+08:00".into(),
        };
        assert_eq!(
            serde_json::to_value(&mute).unwrap(),
            serde_json::json!({
                "op": "add",
                "member_openid": "M1",
                "mute_expire_at": "2026-10-29T15:29:37+08:00",
            })
        );
        // As QQ answered on 2026-10-29, with a name left out.
        let body = br#"{"global_rule":{"mode":"none","schedule_rules":[],"recurring_rules":[]},
            "members":[{"member_openid":"M1","mute_expire_at":"2026-10-29T15:29:36+08:00","username":"x","union_openid":""}]}"#;
        let path = "/v2/groups/G1/restrict_chat_setting";
        let value: serde_json::Value = decode(path, StatusCode::OK, body).unwrap();
        let muted: Vec<Muted> = serde_json::from_value(value["members"].clone()).unwrap();
        assert_eq!(muted[0].member_openid, "M1");
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
