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
    /// Without it, media aren't downloaded and the model sees only what
    /// QQ said about them.
    pub media: Option<Media>,
    /// Without it, `web_search` tells the program there is none.
    pub search: Option<Search>,
    /// Without it, stickers aren't embedded, and `find_stickers` tells the
    /// program there is no library.
    pub embedding: Option<Embedding>,
    /// Max's GitHub account, which the guests' commits are by. Without
    /// it, they have no author set.
    pub github: Option<GitHub>,
    /// The HTTP APIs the VMs call through the host, which adds their keys,
    /// by the name in `/api/<name>/…`.
    #[serde(default)]
    pub api: BTreeMap<String, Api>,
}

/// The model that turns text into vectors for search by meaning; see
/// "发图". Its vectors must be 1024 long, as the schema's are: bge-m3's.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Embedding {
    /// An OpenAI-compatible API's, ending in `/v1`.
    pub base_url: String,
    pub model: String,
    pub api_key_file: Option<PathBuf>,
}

impl Embedding {
    pub fn api_key(&self) -> Result<Option<String>> {
        self.api_key_file.as_deref().map(secret).transpose()
    }
}

/// Web search, through Exa; see "网页搜索".
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Search {
    pub api_key_file: PathBuf,
}

impl Search {
    pub fn api_key(&self) -> Result<String> {
        secret(&self.api_key_file)
    }
}

/// Max's GitHub account, which the guests' commits are by; its token
/// is an API's, `[api.github]`. See "GitHub".
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GitHub {
    pub login: String,
    /// The account's number, for its commits' noreply address.
    pub user_id: u64,
}

impl GitHub {
    /// Who the guests' commits are by: the account, at its noreply address.
    fn author(&self) -> Author {
        Author {
            name: self.login.clone(),
            email: format!("{}+{}@users.noreply.github.com", self.user_id, self.login),
        }
    }

    fn check(&self) -> Result<()> {
        // It goes on the guests' command line, which splits at spaces.
        ensure!(
            !self.login.is_empty()
                && self
                    .login
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-'),
            "{:?} isn't a GitHub login",
            self.login
        );
        Ok(())
    }
}

/// An HTTP API the VMs call through the host: their calls go on to
/// `base_url` with its secret, which stays on the host; see "宿主带 key 的
/// API".
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Api {
    /// What follows `/api/<name>` in a VM's call follows this.
    pub base_url: String,
    pub secret_file: PathBuf,
    /// Headers every call carries, `{secret}` in them standing for the
    /// secret, such as `Authorization = "Bearer {secret}"`.
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    /// Query parameters likewise, for APIs that take their key in the URL.
    #[serde(default)]
    pub query: BTreeMap<String, String>,
    /// The calls it allows, such as `POST /emails`; without it, any.
    pub allow: Option<Vec<Rule>>,
    /// Calls an hour, from all the groups together.
    pub per_hour: Option<u32>,
    /// What the model reads about it: what it is for, where its docs are.
    pub about: String,
}

impl Api {
    pub fn secret(&self) -> Result<String> {
        secret(&self.secret_file)
    }

    fn check(&self) -> Result<()> {
        let url = reqwest::Url::parse(&self.base_url).wrap_err("in base_url")?;
        ensure!(
            matches!(url.scheme(), "https" | "http")
                && url.host().is_some()
                && url.query().is_none()
                && url.fragment().is_none(),
            "{:?} isn't an API's base URL",
            self.base_url
        );
        ensure!(
            self.headers
                .values()
                .chain(self.query.values())
                .any(|value| value.contains("{secret}")),
            "no header or query parameter carries the {{secret}}"
        );
        for (name, value) in &self.headers {
            reqwest::header::HeaderName::from_bytes(name.as_bytes())
                .wrap_err_with(|| format!("{name:?} isn't a header's name"))?;
            reqwest::header::HeaderValue::from_str(&value.replace("{secret}", "secret"))
                .wrap_err_with(|| format!("{value:?} isn't a header's value"))?;
        }
        ensure!(self.per_hour != Some(0), "per_hour is 0");
        ensure!(!self.about.trim().is_empty(), "about is empty");
        Ok(())
    }
}

/// A call an API allows: a method, or `*` for any, and a path below its
/// base URL, where a `*` segment stands for any one segment and a last
/// `**` for anything below.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(try_from = "String")]
pub struct Rule {
    text: String,
    method: Option<String>,
    segments: Vec<String>,
}

impl TryFrom<String> for Rule {
    type Error = String;

    fn try_from(text: String) -> Result<Self, String> {
        let wrong = || format!("{text:?} isn't a call like `POST /emails`");
        let (method, path) = text.split_once(' ').ok_or_else(wrong)?;
        let method = match method {
            "*" => None,
            _ if !method.is_empty() && method.bytes().all(|byte| byte.is_ascii_uppercase()) => {
                Some(method.to_owned())
            }
            _ => return Err(wrong()),
        };
        let segments: Vec<String> = path
            .strip_prefix('/')
            .ok_or_else(wrong)?
            .split('/')
            .map(str::to_owned)
            .collect();
        let deep = segments.iter().position(|segment| segment == "**");
        if deep.is_some_and(|at| at + 1 != segments.len())
            || segments
                .iter()
                .any(|segment| segment == "." || segment == ".." || segment.contains(' '))
        {
            return Err(wrong());
        }
        Ok(Self {
            text,
            method,
            segments,
        })
    }
}

impl Rule {
    /// Whether it allows `method` on `path`, which begins with `/`.
    pub fn allows(&self, method: &str, path: &str) -> bool {
        if self.method.as_deref().is_some_and(|own| own != method) {
            return false;
        }
        let Some(path) = path.strip_prefix('/') else {
            return false;
        };
        let mut given = path.split('/');
        for segment in &self.segments {
            if segment == "**" {
                return true;
            }
            match given.next() {
                Some(part) if part == segment || (segment == "*" && !part.is_empty()) => {}
                _ => return false,
            }
        }
        given.next().is_none()
    }
}

impl std::fmt::Display for Rule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.text)
    }
}

/// Who a guest's commits are by.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Author {
    pub name: String,
    pub email: String,
}

/// Where downloaded media go; see "媒体".
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Media {
    /// The content store is `objects/` in here.
    pub dir: PathBuf,
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
    /// The model that says in words what a picture or sticker shows. It
    /// has to see pictures. Without it, nothing is captioned.
    pub caption: Option<Selection>,
    /// The model background agents use: pi, in the group's VM, which
    /// reaches it through the VM's MCP service. Without it, there are no
    /// background agents.
    pub job: Option<Selection>,
    /// The model that tidies Max's memory files at night. Without it,
    /// they aren't tidied.
    pub dreamer: Option<Selection>,
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
    /// A VM stops after this long without a command, unless it is kept on.
    #[serde(default = "vm_idle")]
    pub idle_minutes: u64,
    /// At most this many groups' VMs are kept on for the units Max keeps
    /// in them; see "常驻程序".
    #[serde(default = "kept")]
    pub kept: usize,
    /// Who the guests' commits are by: Max's GitHub account, from
    /// `[github]`.
    #[serde(skip)]
    pub author: Option<Author>,
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

fn kept() -> usize {
    4
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
        let mut config: Self = toml::from_str(text)?;
        config.llm.check()?;
        if let Some(vm) = &config.vm {
            vm.check().wrap_err("in vm")?;
        }
        if let Some(github) = &config.github {
            github.check().wrap_err("in github")?;
        }
        for (name, api) in &config.api {
            ensure!(
                !name.is_empty()
                    && name.bytes().all(|byte| byte.is_ascii_lowercase()
                        || byte.is_ascii_digit()
                        || byte == b'-'),
                "{name:?} isn't an API's name: lowercase letters, digits and -"
            );
            api.check().wrap_err_with(|| format!("in api.{name}"))?;
        }
        if let (Some(vm), Some(github)) = (&mut config.vm, &config.github) {
            vm.author = Some(github.author());
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
            ("caption", self.caption.as_ref()),
            ("job", self.job.as_ref()),
            ("dreamer", self.dreamer.as_ref()),
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
        caption = { model = "cliproxy/gpt-5.6-luna", effort = "low" }

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

            [media]
            dir = "/var/lib/maxx/media"

            [search]
            api_key_file = "/run/secrets/maxx/exa-api-key"

            [embedding]
            base_url = "http://ollama.example:11434/v1"
            model = "bge-m3"
            "#,
        )
        .unwrap();
        let embedding = config.embedding.as_ref().unwrap();
        assert_eq!(embedding.model, "bge-m3");
        assert_eq!(embedding.api_key().unwrap(), None);
        let search = config.search.as_ref().unwrap();
        assert_eq!(
            search.api_key_file,
            Path::new("/run/secrets/maxx/exa-api-key")
        );
        assert_eq!(config.log.level, Level::Debug);
        assert_eq!(config.media.unwrap().dir, Path::new("/var/lib/maxx/media"));
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
        assert!(config.embedding.is_none());

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
        assert_eq!(config.author, None);
        let github = "[github]\nlogin = \"maxxbot\"\nuser_id = 42\n";
        let config = with_llm(&format!("{vm}{github}")).unwrap().vm.unwrap();
        assert_eq!(
            config.author,
            Some(Author {
                name: "maxxbot".into(),
                email: "42+maxxbot@users.noreply.github.com".into(),
            })
        );
        let spaced = github.replace("maxxbot", "maxx bot");
        assert!(with_llm(&format!("{vm}{spaced}")).is_err());

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
    fn apis() {
        let api = r#"
            [database]
            url = "postgresql:///max"

            [api.mail]
            base_url = "https://mail.example/v1"
            secret_file = "/run/secrets/maxx/mail-api-key"
            headers = { Authorization = "Bearer {secret}", Mail-Version = "2026-01" }
            allow = ["POST /emails", "GET /emails/*"]
            per_hour = 20
            about = "发邮件。"
        "#;
        let config = with_llm(api).unwrap();
        let mail = &config.api["mail"];
        assert_eq!(mail.per_hour, Some(20));
        assert_eq!(mail.headers["Mail-Version"], "2026-01");
        let allow = mail.allow.as_ref().unwrap();
        assert_eq!(allow[1].to_string(), "GET /emails/*");

        let keyless = api.replace("Bearer {secret}", "Bearer");
        let error = with_llm(&keyless).unwrap_err();
        assert!(format!("{error:#}").contains("in api.mail"), "{error:#}");
        let in_query = keyless.replace("per_hour", "query = { key = \"{secret}\" }\nper_hour");
        assert!(with_llm(&in_query).is_ok());
        for wrong in [
            api.replace("[api.mail]", "[api.Mail]"),
            api.replace("https://mail.example/v1", "mail.example/v1"),
            api.replace("https://mail.example/v1", "https://mail.example/v1?key=1"),
            api.replace("POST /emails", "post /emails"),
            api.replace("POST /emails", "POST emails"),
            api.replace("POST /emails", "POST /**/emails"),
            api.replace("POST /emails", "POST /../emails"),
            api.replace("per_hour = 20", "per_hour = 0"),
            api.replace("Mail-Version", "\"Mail Version\""),
        ] {
            assert!(with_llm(&wrong).is_err(), "{wrong}");
        }
    }

    #[test]
    fn rules_match_methods_and_paths() {
        let rule = |text: &str| Rule::try_from(text.to_owned()).unwrap();
        let send = rule("POST /emails");
        assert!(send.allows("POST", "/emails"));
        assert!(!send.allows("GET", "/emails"));
        assert!(!send.allows("POST", "/emails/batch"));
        assert!(!send.allows("POST", "/"));
        let one = rule("GET /emails/*");
        assert!(one.allows("GET", "/emails/re_123"));
        assert!(!one.allows("GET", "/emails/"));
        assert!(!one.allows("GET", "/emails/re_123/attachments"));
        let below = rule("* /domains/**");
        assert!(below.allows("DELETE", "/domains"));
        assert!(below.allows("GET", "/domains/d_1/verify"));
        assert!(!below.allows("GET", "/domainsx"));
        assert!(rule("GET /").allows("GET", "/"));
        assert!(!rule("GET /").allows("GET", "/emails"));
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
        let caption = format!(
            "{database}{}",
            LLM.replace(
                "caption = { model = \"cliproxy/gpt-5.6-luna\"",
                "caption = { model = \"cliproxy/gpt-9\""
            )
        );
        let error = Config::parse(&caption).unwrap_err();
        assert!(format!("{error:#}").contains("in llm.caption"), "{error:#}");
        let without = format!("{database}{}", LLM.replace("caption = ", "# caption = "));
        assert!(Config::parse(&without).unwrap().llm.caption.is_none());
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
