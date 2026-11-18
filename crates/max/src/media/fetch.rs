//! Downloading a medium: one GET, read up to a limit.

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
#[derive(Debug)]
pub struct Body {
    response: Response,
    most: u64,
    read: u64,
}

#[derive(Debug, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    /// More than the limit: only what QQ said about it is kept.
    #[error("too large")]
    TooLarge,
    /// The server's answer, such as 404 for an address that expired.
    #[error("HTTP {0}")]
    Status(u16),
    /// The connection failed or timed out.
    #[error("{0}")]
    Failed(String),
}

impl Error {
    /// A server error or a broken connection may go another way next
    /// time; an expired address or a file too large won't.
    #[must_use]
    pub fn is_retryable(&self) -> bool {
        match self {
            Self::TooLarge => false,
            Self::Status(status) => *status >= 500 || *status == 429,
            Self::Failed(_) => true,
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
