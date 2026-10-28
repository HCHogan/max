//! The configuration file, the one place settings come from. Parsing is
//! strict: an unknown key is an error, defaults are written here and
//! nowhere else, and an optional feature is an optional section. Secrets,
//! and identifiers that shouldn't be public, are paths to files, read when
//! Max starts.

use std::fs;
use std::path::{Path, PathBuf};

use color_eyre::eyre::{Result, WrapErr, ensure};
use serde::Deserialize;
use tracing::level_filters::LevelFilter;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    #[serde(default)]
    pub log: Log,
    pub database: Database,
    #[serde(default)]
    pub platforms: Platforms,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Log {
    #[serde(default)]
    pub level: Level,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Level {
    Error,
    Warn,
    #[default]
    Info,
    Debug,
    Trace,
}

impl From<Level> for LevelFilter {
    fn from(level: Level) -> Self {
        match level {
            Level::Error => Self::ERROR,
            Level::Warn => Self::WARN,
            Level::Info => Self::INFO,
            Level::Debug => Self::DEBUG,
            Level::Trace => Self::TRACE,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Database {
    /// For example `postgresql://max@/max?host=/run/postgresql`.
    pub url: String,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Platforms {
    pub qq: Option<Qq>,
}

/// Tencent's official bot API.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Qq {
    pub app_id_file: PathBuf,
    pub app_secret_file: PathBuf,
}

impl Config {
    /// Reads and checks the file, without reading the secrets it names.
    pub fn load(path: &Path) -> Result<Self> {
        let text = fs::read_to_string(path)
            .wrap_err_with(|| format!("reading the configuration {}", path.display()))?;
        Self::parse(&text).wrap_err_with(|| format!("in the configuration {}", path.display()))
    }

    fn parse(text: &str) -> Result<Self> {
        Ok(toml::from_str(text)?)
    }
}

impl Qq {
    pub fn credentials(&self) -> Result<qqbot::Credentials> {
        Ok(qqbot::Credentials {
            app_id: secret(&self.app_id_file)?,
            secret: secret(&self.app_secret_file)?,
        })
    }
}

/// A secret's file, which holds the value and maybe a final newline.
fn secret(path: &Path) -> Result<String> {
    let text = fs::read_to_string(path)
        .wrap_err_with(|| format!("reading the secret {}", path.display()))?;
    let value = text.trim_end_matches(['\r', '\n']);
    ensure!(!value.is_empty(), "the secret {} is empty", path.display());
    Ok(value.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_whole_file() {
        let config = Config::parse(
            r#"
            [log]
            level = "debug"

            [database]
            url = "postgresql://maxx@/maxx?host=/run/postgresql"

            [platforms.qq]
            app_id_file = "/run/secrets/maxx/qq-app-id"
            app_secret_file = "/run/secrets/maxx/qq-app-secret"
            "#,
        )
        .unwrap();
        assert_eq!(config.log.level, Level::Debug);
        let qq = config.platforms.qq.unwrap();
        assert_eq!(qq.app_id_file, Path::new("/run/secrets/maxx/qq-app-id"));
    }

    #[test]
    fn defaults_and_mistakes() {
        let config = Config::parse("[database]\nurl = \"postgresql:///max\"").unwrap();
        assert_eq!(config.log.level, Level::Info);
        assert!(config.platforms.qq.is_none());

        let misspelt = "[database]\nurl = \"postgresql:///max\"\n[logs]\nlevel = \"debug\"";
        let error = Config::parse(misspelt).unwrap_err();
        assert!(
            format!("{error:#}").contains("unknown field `logs`"),
            "{error:#}"
        );
        assert!(Config::parse("[log]\nlevel = \"debug\"").is_err());
        let loud = "[database]\nurl = \"postgresql:///max\"\n[log]\nlevel = \"loud\"";
        assert!(Config::parse(loud).is_err());
    }

    #[test]
    fn secrets() {
        let dir = std::env::temp_dir().join(format!("max-config-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let (id, secret) = (dir.join("id"), dir.join("secret"));
        fs::write(&id, "1000\n").unwrap();
        fs::write(&secret, "").unwrap();
        let qq = Qq {
            app_id_file: id,
            app_secret_file: secret.clone(),
        };
        let error = qq.credentials().unwrap_err();
        assert!(error.to_string().contains("is empty"), "{error}");
        fs::write(&secret, "s3cret").unwrap();
        let credentials = qq.credentials().unwrap();
        assert_eq!(
            (credentials.app_id.as_str(), credentials.secret.as_str()),
            ("1000", "s3cret")
        );
        fs::remove_dir_all(&dir).unwrap();
        assert!(qq.credentials().is_err());
    }
}
