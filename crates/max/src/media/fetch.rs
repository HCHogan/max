//! Downloading a medium: one GET, read up to a limit.

use std::fmt;
use std::time::Duration;

use reqwest::{Client, header};

/// What a download may take, from connecting to the last byte.
pub const TIMEOUT: Duration = Duration::from_secs(60);

/// The client downloads go through.
pub fn client() -> reqwest::Result<Client> {
    Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(TIMEOUT)
        .build()
}

/// The bytes, and what the server said they are.
#[derive(Debug)]
pub struct Fetched {
    pub bytes: Vec<u8>,
    pub mime: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// More than the limit: only what QQ said about it is kept.
    TooLarge,
    /// The server's answer, such as 404 for an address that expired.
    Status(u16),
    /// The connection failed or timed out.
    Failed(String),
}

impl Error {
    /// A server error or a broken connection may go another way next
    /// time; an expired address or a file too large won't.
    pub fn retryable(&self) -> bool {
        match self {
            Self::TooLarge => false,
            Self::Status(status) => *status >= 500 || *status == 429,
            Self::Failed(_) => true,
        }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLarge => write!(f, "too large"),
            Self::Status(status) => write!(f, "HTTP {status}"),
            Self::Failed(error) => write!(f, "{error}"),
        }
    }
}

/// Downloads `url`, giving up past `most` bytes.
pub async fn fetch(http: &Client, url: &str, most: u64) -> Result<Fetched, Error> {
    let failed = |error: reqwest::Error| Error::Failed(error.to_string());
    let mut response = http.get(url).send().await.map_err(failed)?;
    let status = response.status();
    if !status.is_success() {
        return Err(Error::Status(status.as_u16()));
    }
    if response
        .content_length()
        .is_some_and(|length| length > most)
    {
        return Err(Error::TooLarge);
    }
    let mime = response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .map(|mime| mime.trim().to_ascii_lowercase())
        .filter(|mime| !mime.is_empty());
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(failed)? {
        if u64::try_from(bytes.len() + chunk.len()).unwrap_or(u64::MAX) > most {
            return Err(Error::TooLarge);
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(Fetched { bytes, mime })
}

#[cfg(test)]
mod tests {
    use axum::Router;
    use axum::http::{StatusCode, header};
    use axum::routing::get;
    use tokio::net::TcpListener;
    use tokio_util::sync::CancellationToken;

    use super::*;

    #[tokio::test]
    async fn bytes_up_to_a_limit() {
        let app = Router::new()
            .route(
                "/a.png",
                get(|| async { ([(header::CONTENT_TYPE, "Image/PNG; x=1")], "abc") }),
            )
            .route("/gone", get(|| async { StatusCode::NOT_FOUND }))
            .route("/busy", get(|| async { StatusCode::SERVICE_UNAVAILABLE }));
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let stop = CancellationToken::new();
        let stopped = stop.clone();
        let server = axum::serve(listener, app).with_graceful_shutdown(stopped.cancelled_owned());
        let http = client().unwrap();
        let test = async {
            let fetched = fetch(&http, &format!("{base}/a.png"), 3).await.unwrap();
            assert_eq!(fetched.bytes, b"abc");
            assert_eq!(fetched.mime.as_deref(), Some("image/png"));
            let large = fetch(&http, &format!("{base}/a.png"), 2).await.unwrap_err();
            assert_eq!(large, Error::TooLarge);
            let gone = fetch(&http, &format!("{base}/gone"), 3).await.unwrap_err();
            assert_eq!(gone, Error::Status(404));
            assert!(!gone.retryable() && !large.retryable());
            let busy = fetch(&http, &format!("{base}/busy"), 3).await.unwrap_err();
            assert!(busy.retryable());
            let refused = fetch(&http, "http://127.0.0.1:9/x", 3).await.unwrap_err();
            assert!(refused.retryable(), "{refused}");
            stop.cancel();
        };
        let (served, ()) = tokio::join!(server.into_future(), test);
        served.unwrap();
    }
}
