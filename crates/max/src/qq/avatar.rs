//! Avatars, as QQ shows them to the bot for an account's openid and to
//! anyone for a QQ number, and how two are compared: what links accounts to
//! old numbers. See "按头像接上" in docs/rust-rewrite.md.

use std::time::Duration;

use color_eyre::eyre::{Result, bail};
use image::imageops::FilterType;
use reqwest::Client;

/// The avatar the bot sees of an account, by app id and openid.
pub const BY_OPENID: &str = "https://q.qlogo.cn/qqapp/{app}/{openid}/640";
/// Anyone's avatar, by QQ number.
pub const BY_NUMBER: &str = "https://q1.qlogo.cn/g?b=qq&nk={number}&s=640";
/// What two avatars are shrunk to before they are compared.
const SIDE: u32 = 16;
/// Avatars closer than this are the same picture. Measured 2026-10-29: one
/// person's two were 0.03% apart, other people's 36–60%.
const ALIKE: f64 = 0.05;
const MOST: usize = 4 << 20;

pub struct Avatars {
    http: Client,
    by_openid: String,
    by_number: String,
}

impl Avatars {
    /// `by_openid` with `{openid}` in it and `by_number` with `{number}`:
    /// QQ's, or a test's.
    pub fn new(by_openid: String, by_number: String) -> reqwest::Result<Self> {
        let http = Client::builder().timeout(Duration::from_secs(5)).build()?;
        Ok(Self {
            http,
            by_openid,
            by_number,
        })
    }

    pub fn qq(app_id: &str) -> reqwest::Result<Self> {
        Self::new(BY_OPENID.replace("{app}", app_id), BY_NUMBER.to_owned())
    }

    /// The print of the avatar of the account with `openid`.
    pub async fn of_account(&self, openid: &str) -> Result<Vec<u8>> {
        print(&self.get(self.by_openid.replace("{openid}", openid)).await?)
    }

    /// The print of the avatar of `number`.
    pub async fn of_number(&self, number: &str) -> Result<Vec<u8>> {
        print(&self.get(self.by_number.replace("{number}", number)).await?)
    }

    /// The print of QQ's default avatar, which an account without one
    /// shows: what QQ shows for an openid that is no one's.
    pub async fn default(&self) -> Result<Vec<u8>> {
        self.of_account("0").await
    }

    async fn get(&self, url: String) -> Result<Vec<u8>> {
        let response = self.http.get(url).send().await?.error_for_status()?;
        let body = response.bytes().await?;
        if body.len() > MOST {
            bail!("an avatar of {} bytes", body.len());
        }
        Ok(body.to_vec())
    }
}

/// What an avatar is compared by: the picture shrunk to 16×16 grey, a byte
/// a pixel.
pub fn print(bytes: &[u8]) -> Result<Vec<u8>> {
    let image = image::load_from_memory(bytes)?;
    let image = image.resize_exact(SIDE, SIDE, FilterType::Triangle);
    Ok(image.to_luma8().into_raw())
}

/// Whether two prints are of one picture: their root-mean-square
/// difference is under `ALIKE` of the full range. Prints of another size
/// never are.
pub fn alike(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let squares: f64 = a
        .iter()
        .zip(b)
        .map(|(x, y)| (f64::from(*x) - f64::from(*y)).powi(2))
        .sum();
    let pixels = f64::from(SIDE * SIDE);
    (squares / pixels).sqrt() / 255.0 < ALIKE
}

#[cfg(test)]
pub mod testing;
#[cfg(test)]
mod tests;
