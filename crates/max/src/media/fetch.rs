//! Downloading a medium: one GET, read up to a limit.

use std::fmt;
use std::time::Duration;

use axum::body::Bytes;
use reqwest::{Client, Response, header};

/// What a download may take, from connecting to the last byte.
pub const TIMEOUT: Duration = Duration::from_secs(60);

/// The client downloads go through.
pub fn client() -> reqwest::Result<Client> {
    Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(TIMEOUT)
        .build()
}

/// A download's body, read as it comes, up to a limit.
pub struct Body {
    response: Response,
    most: u64,
    read: u64,
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

/// Starts downloading `url`, and says what the server said it is. One
/// the server says is over `most` bytes is refused.
pub async fn open(http: &Client, url: &str, most: u64) -> Result<(Body, Option<String>), Error> {
    let response = http.get(url).send().await.map_err(failed)?;
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
    let body = Body {
        response,
        most,
        read: 0,
    };
    Ok((body, mime))
}

impl Body {
    /// The next piece, None at the end. Past the limit, the download is
    /// too large.
    pub async fn chunk(&mut self) -> Result<Option<Bytes>, Error> {
        let Some(chunk) = self.response.chunk().await.map_err(failed)? else {
            return Ok(None);
        };
        self.read = self.read.saturating_add(chunk.len() as u64);
        if self.read > self.most {
            return Err(Error::TooLarge);
        }
        Ok(Some(chunk))
    }

    /// The whole body: `head`, what was read of it already, and the rest.
    pub async fn rest(mut self, mut head: Vec<u8>) -> Result<Vec<u8>, Error> {
        // As long as the server says, which is within the limit.
        let length = self.response.content_length().unwrap_or(0);
        head.reserve(
            usize::try_from(length)
                .unwrap_or(0)
                .saturating_sub(head.len()),
        );
        while let Some(chunk) = self.chunk().await? {
            head.extend_from_slice(&chunk);
        }
        Ok(head)
    }
}

fn failed(error: reqwest::Error) -> Error {
    Error::Failed(error.to_string())
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
        let fetch = async |url: &str, most| {
            let (body, mime) = open(&http, url, most).await?;
            Ok::<_, Error>((body.rest(Vec::new()).await?, mime))
        };
        let test = async {
            let (bytes, mime) = fetch(&format!("{base}/a.png"), 3).await.unwrap();
            assert_eq!(bytes, b"abc");
            assert_eq!(mime.as_deref(), Some("image/png"));
            let large = fetch(&format!("{base}/a.png"), 2).await.unwrap_err();
            assert_eq!(large, Error::TooLarge);
            let gone = fetch(&format!("{base}/gone"), 3).await.unwrap_err();
            assert_eq!(gone, Error::Status(404));
            assert!(!gone.retryable() && !large.retryable());
            let busy = fetch(&format!("{base}/busy"), 3).await.unwrap_err();
            assert!(busy.retryable());
            let refused = fetch("http://127.0.0.1:9/x", 3).await.unwrap_err();
            assert!(refused.retryable(), "{refused}");
            stop.cancel();
        };
        let (served, ()) = tokio::join!(server.into_future(), test);
        served.unwrap();
    }
}
