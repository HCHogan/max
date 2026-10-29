//! The configuration file, the one place settings come from. Parsing is
//! strict: an unknown key is an error, defaults are written here and
//! nowhere else, and an optional feature is an optional section. Secrets,
//! and identifiers that shouldn't be public, are paths to files, read when
//! Max starts.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use chrono::FixedOffset;
use color_eyre::eyre::{Result, WrapErr, bail, ensure, eyre};
use max_core::item::Protocol;
use serde::Deserialize;
use tracing::level_filters::LevelFilter;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    /// The time zone for the clock the model reads, such as `+08:00`.
    #[serde(default = "china", deserialize_with = "offset")]
    pub utc_offset: FixedOffset,
    /// `platform:native id` per line, such as `qq:<user_openid>`.
    pub owners_file: Option<PathBuf>,
    #[serde(default)]
    pub log: Log,
    pub database: Database,
    pub llm: Llm,
    #[serde(default)]
    pub platforms: Platforms,
    /// Without it, the tools tell the model there is no VM.
    pub vm: Option<Vm>,
}

fn china() -> FixedOffset {
    FixedOffset::east_opt(8 * 3600).expect("+08:00 is in range")
}

fn offset<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<FixedOffset, D::Error> {
    let text = String::deserialize(deserializer)?;
    text.parse()
        .map_err(|_| serde::de::Error::custom(format!("{text:?} isn't an offset like +08:00")))
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
    /// For example `postgresql:///max?host=/run/postgresql&user=max`, over
    /// the socket. `postgresql://max@/max` isn't a URL: a user needs a host.
    pub url: String,
}

/// Models in three layers: how to reach a provider, what each of its
/// models is, and who uses which. See "LLM：provider、模型、选用".
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Llm {
    /// What turns use, unless a conversation chose another with `/model`.
    pub default: Selection,
    /// The small model that judges chatter.
    pub intent: Selection,
    /// The model that summarizes what was said. Without it, no summaries
    /// are written, and the raw tail is cut when it grows too long.
    pub historian: Option<Selection>,
    pub providers: BTreeMap<String, Provider>,
}

/// A model by `provider/model`, split at the first `/`, and how hard it
/// should think.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Selection {
    pub model: String,
    pub effort: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Provider {
    pub base_url: String,
    pub protocol: ProtocolName,
    pub api_key_file: Option<PathBuf>,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    /// Attempts after the first, for errors worth retrying, and only while
    /// nothing has been said.
    #[serde(default = "retries")]
    pub retries: u32,
    /// The response's headers and every piece after them must arrive
    /// within this; a call as a whole has no limit.
    #[serde(default = "stream_idle_timeout")]
    pub stream_idle_timeout_secs: u64,
    /// A core ends after this long idle: about as long as the provider
    /// keeps a prefix cached.
    #[serde(default = "idle_window")]
    pub idle_window_secs: u64,
    /// Mark the stable blocks for servers that cache only where told to
    /// (NInfer). Chat only.
    #[serde(default)]
    pub cache_breakpoints: bool,
    pub models: BTreeMap<String, Model>,
}

fn retries() -> u32 {
    2
}

fn stream_idle_timeout() -> u64 {
    120
}

fn idle_window() -> u64 {
    300
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProtocolName {
    Responses,
    Chat,
}

impl From<ProtocolName> for Protocol {
    fn from(name: ProtocolName) -> Self {
        match name {
            ProtocolName::Responses => Self::Responses,
            ProtocolName::Chat => Self::Chat,
        }
    }
}

/// The table's name is the model id sent to the API.
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Model {
    pub context_window: u32,
    pub max_output: Option<u32>,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
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

/// The groups' VMs; see "VM 进程". The NixOS module fills this in: the
/// programs, and the taps it made.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Vm {
    /// The guest's kernel, initrd and command line, as the flake's `guest`
    /// writes them.
    pub guest: PathBuf,
    pub cloud_hypervisor: PathBuf,
    pub virtiofsd: PathBuf,
    /// mkfs.ext4, for a new VM's store disk.
    pub mkfs: PathBuf,
    /// Each conversation's VM keeps its files in a directory here.
    pub dir: PathBuf,
    /// One per VM that can run at a time.
    pub slots: Vec<Slot>,
    /// The resolvers a guest uses.
    pub dns: Vec<String>,
    #[serde(default = "cpus")]
    pub cpus: u32,
    #[serde(default = "memory")]
    pub memory_mib: u32,
    /// The disk that holds what the guest adds to the store.
    #[serde(default = "disk")]
    pub disk_gib: u32,
    /// A VM stops after this long without a command.
    #[serde(default = "vm_idle")]
    pub idle_minutes: u64,
}

fn cpus() -> u32 {
    2
}

fn memory() -> u32 {
    4096
}

fn disk() -> u32 {
    64
}

fn vm_idle() -> u64 {
    120
}

/// A tap made for max, and the guest's address behind it.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Slot {
    pub tap: String,
    /// The guest's, with its prefix, such as `10.235.0.2/30`.
    pub address: String,
    /// The host's end of the tap.
    pub gateway: String,
}

impl Config {
    /// Reads and checks the file, without reading the secrets it names.
    pub fn load(path: &Path) -> Result<Self> {
        let text = fs::read_to_string(path)
            .wrap_err_with(|| format!("reading the configuration {}", path.display()))?;
        Self::parse(&text).wrap_err_with(|| format!("in the configuration {}", path.display()))
    }

    fn parse(text: &str) -> Result<Self> {
        let config: Self = toml::from_str(text)?;
        config.llm.check()?;
        if let Some(vm) = &config.vm {
            vm.check().wrap_err("in vm")?;
        }
        Ok(config)
    }

    /// The owners' accounts, as `(platform, native id)`.
    pub fn owners(&self) -> Result<Vec<(String, String)>> {
        let Some(path) = &self.owners_file else {
            return Ok(Vec::new());
        };
        lines(path)?
            .into_iter()
            .map(|line| {
                let (platform, id) = line
                    .split_once(':')
                    .ok_or_else(|| eyre!("{}: {line:?} isn't platform:id", path.display()))?;
                Ok((platform.trim().to_owned(), id.trim().to_owned()))
            })
            .collect()
    }
}

impl Llm {
    /// Every selection names a model that is configured.
    fn check(&self) -> Result<()> {
        for name in self.providers.keys() {
            ensure!(!name.contains('/'), "a provider's name has a /: {name:?}");
        }
        let selections = [
            ("default", Some(&self.default)),
            ("intent", Some(&self.intent)),
            ("historian", self.historian.as_ref()),
        ];
        for (role, selection) in selections {
            if let Some(selection) = selection {
                self.model(&selection.model)
                    .wrap_err_with(|| format!("in llm.{role}"))?;
            }
        }
        Ok(())
    }

    /// The provider and the model a `provider/model` reference names.
    pub fn model(&self, reference: &str) -> Result<(&str, &Provider, &str, &Model)> {
        let Some((provider_name, model_name)) = reference.split_once('/') else {
            bail!("{reference:?} isn't provider/model");
        };
        let (provider_name, provider) = self
            .providers
            .get_key_value(provider_name)
            .ok_or_else(|| eyre!("no provider {provider_name:?}"))?;
        let (model_name, model) = provider
            .models
            .get_key_value(model_name)
            .ok_or_else(|| eyre!("{provider_name:?} has no model {model_name:?}"))?;
        Ok((provider_name, provider, model_name, model))
    }
}

impl Vm {
    fn check(&self) -> Result<()> {
        ensure!(!self.slots.is_empty(), "no slots");
        let mut taps: Vec<&str> = self.slots.iter().map(|slot| slot.tap.as_str()).collect();
        taps.sort_unstable();
        taps.dedup();
        ensure!(
            taps.len() == self.slots.len(),
            "two slots have the same tap"
        );
        // The taps are multi-queue, which cloud-hypervisor opens as such
        // only with two queue pairs or more, and it allows a pair per vCPU.
        ensure!(self.cpus >= 2, "a VM needs two vCPUs at least");
        ensure!(self.memory_mib >= 512, "too small a VM");
        // They go on the guest's command line, which splits at spaces.
        for word in self.dns.iter().chain(
            self.slots
                .iter()
                .flat_map(|slot| [&slot.address, &slot.gateway]),
        ) {
            ensure!(
                !word.is_empty() && !word.contains([' ', ',']),
                "{word:?} isn't an address"
            );
        }
        Ok(())
    }
}

impl Provider {
    pub fn api_key(&self) -> Result<Option<String>> {
        self.api_key_file.as_deref().map(secret).transpose()
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

/// A list file's lines, trimmed, without blank ones and `#` comments.
fn lines(path: &Path) -> Result<Vec<String>> {
    let text = fs::read_to_string(path)
        .wrap_err_with(|| format!("reading the list {}", path.display()))?;
    Ok(text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(str::to_owned)
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    const LLM: &str = r#"
        [llm]
        default = { model = "cliproxy/gpt-5.6-luna", effort = "xhigh" }
        intent = { model = "local/qwen3.5-4b" }
        historian = { model = "cliproxy/gpt-5.6-luna", effort = "medium" }

        [llm.providers.cliproxy]
        base_url = "https://cliproxy.example/v1"
        protocol = "responses"
        api_key_file = "/run/secrets/maxx/cliproxy-api-key"

        [llm.providers.cliproxy.models."gpt-5.6-luna"]
        context_window = 400000
        max_output = 128000

        [llm.providers.local]
        base_url = "http://127.0.0.1:8080/v1"
        protocol = "chat"
        cache_breakpoints = true

        [llm.providers.local.models."qwen3.5-4b"]
        context_window = 32768
    "#;

    fn with_llm(text: &str) -> Result<Config> {
        Config::parse(&format!("{text}\n{LLM}"))
    }

    #[test]
    fn a_whole_file() {
        let config = with_llm(
            r#"
            utc_offset = "+09:00"
            owners_file = "/run/secrets/maxx/owners"

            [log]
            level = "debug"

            [database]
            url = "postgresql:///maxx?host=/run/postgresql&user=maxx"

            [platforms.qq]
            app_id_file = "/run/secrets/maxx/qq-app-id"
            app_secret_file = "/run/secrets/maxx/qq-app-secret"
            "#,
        )
        .unwrap();
        assert_eq!(config.log.level, Level::Debug);
        assert_eq!(config.utc_offset.local_minus_utc(), 9 * 3600);
        let qq = config.platforms.qq.unwrap();
        assert_eq!(qq.app_id_file, Path::new("/run/secrets/maxx/qq-app-id"));
        let (provider, settings, model, _) = config.llm.model("cliproxy/gpt-5.6-luna").unwrap();
        assert_eq!((provider, model), ("cliproxy", "gpt-5.6-luna"));
        assert_eq!(settings.protocol, ProtocolName::Responses);
        assert_eq!((settings.retries, settings.idle_window_secs), (2, 300));
    }

    #[test]
    fn defaults_and_mistakes() {
        let config = with_llm("[database]\nurl = \"postgresql:///max\"").unwrap();
        assert_eq!(config.log.level, Level::Info);
        assert_eq!(config.utc_offset.local_minus_utc(), 8 * 3600);
        assert!(config.platforms.qq.is_none());

        let misspelt = "[database]\nurl = \"postgresql:///max\"\n[logs]\nlevel = \"debug\"";
        let error = with_llm(misspelt).unwrap_err();
        assert!(
            format!("{error:#}").contains("unknown field `logs`"),
            "{error:#}"
        );
        assert!(with_llm("[log]\nlevel = \"debug\"").is_err());
        let loud = "[database]\nurl = \"postgresql:///max\"\n[log]\nlevel = \"loud\"";
        assert!(with_llm(loud).is_err());
        assert!(Config::parse("[database]\nurl = \"postgresql:///max\"").is_err());
    }

    #[test]
    fn vms() {
        let vm = r#"
            [database]
            url = "postgresql:///max"

            [vm]
            guest = "/nix/store/x-max-guest.json"
            cloud_hypervisor = "/nix/store/x-cloud-hypervisor/bin/cloud-hypervisor"
            virtiofsd = "/nix/store/x-virtiofsd/bin/virtiofsd"
            mkfs = "/nix/store/x-e2fsprogs/bin/mkfs.ext4"
            dir = "/var/lib/maxx/vm"
            dns = ["223.5.5.5", "119.29.29.29"]
            memory_mib = 8192

            [[vm.slots]]
            tap = "maxx-vm0"
            address = "10.235.0.2/30"
            gateway = "10.235.0.1"
        "#;
        let config = with_llm(vm).unwrap().vm.unwrap();
        assert_eq!((config.cpus, config.memory_mib), (2, 8192));
        assert_eq!(config.slots[0].tap, "maxx-vm0");

        let twice = vm.replace(
            "[[vm.slots]]",
            "[[vm.slots]]\ntap = \"maxx-vm0\"\naddress = \"10.235.0.6/30\"\ngateway = \"10.235.0.5\"\n[[vm.slots]]",
        );
        let error = with_llm(&twice).unwrap_err();
        assert!(format!("{error:#}").contains("same tap"), "{error:#}");
        let spaced = vm.replace("223.5.5.5", "223.5.5.5 x");
        assert!(with_llm(&spaced).is_err());
        let one = vm.replace("memory_mib = 8192", "cpus = 1");
        let error = with_llm(&one).unwrap_err();
        assert!(format!("{error:#}").contains("two vCPUs"), "{error:#}");
    }

    #[test]
    fn selections_name_configured_models() {
        let database = "[database]\nurl = \"postgresql:///max\"\n";
        let missing = format!(
            "{database}{}",
            LLM.replace("local/qwen3.5-4b", "local/qwen9")
        );
        let error = Config::parse(&missing).unwrap_err();
        assert!(
            format!("{error:#}").contains("in llm.intent: \"local\" has no model \"qwen9\""),
            "{error:#}"
        );
        let bare = format!(
            "{database}{}",
            LLM.replace("local/qwen3.5-4b", "qwen3.5-4b")
        );
        assert!(Config::parse(&bare).is_err());
        let historian = format!(
            "{database}{}",
            LLM.replace(
                "historian = { model = \"cliproxy/gpt-5.6-luna\"",
                "historian = { model = \"cliproxy/gpt-9\""
            )
        );
        let error = Config::parse(&historian).unwrap_err();
        assert!(
            format!("{error:#}").contains("in llm.historian"),
            "{error:#}"
        );
        let without = format!(
            "{database}{}",
            LLM.replace("historian = ", "# historian = ")
        );
        assert!(Config::parse(&without).unwrap().llm.historian.is_none());
    }

    #[test]
    fn secrets_and_lists() {
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

        let owners = dir.join("owners");
        fs::write(&owners, "# the owner\nqq:ABCDEF0123\n\n  qq:0123ABCDEF  \n").unwrap();
        let mut config = with_llm("[database]\nurl = \"postgresql:///max\"").unwrap();
        config.owners_file = Some(owners);
        assert_eq!(
            config.owners().unwrap(),
            [
                ("qq".to_owned(), "ABCDEF0123".to_owned()),
                ("qq".to_owned(), "0123ABCDEF".to_owned())
            ]
        );
        fs::remove_dir_all(&dir).unwrap();
        assert!(qq.credentials().is_err());
    }
}
