//! Max's GitHub account, for `github` and `github_push`. Its token stays
//! on the host. The REST API is called for Max, which may read anything
//! but write only what is its own, or open a pull request. Commits come
//! from the guest as a git bundle, which a bare repository of the host's
//! own takes in and pushes to Max's fork: git never runs in a repository
//! the guest wrote, whose configuration could run commands. See "GitHub"
//! in docs/rust-rewrite.md.

#[cfg(test)]
mod tests;

use std::fmt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use chrono::{SecondsFormat, Utc};
use reqwest::{Client, Method, StatusCode, Url};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use tokio::process::Command;
use tokio::sync::Mutex;
use tokio::time::{Instant, sleep, timeout};
use tracing::{info, warn};

pub const API: &str = "https://api.github.com";
pub const GIT: &str = "https://github.com";
/// New pull requests in a day, from every conversation: GitHub suspends
/// accounts that look like spam.
pub const DAILY: u64 = 10;
/// Under every pull request's description.
pub const FOOTER: &str =
    "---\n*Opened by Max, an AI assistant, at the request of someone in a group chat it's in.*";
/// How long a new fork gets to appear.
const FORKING: Duration = Duration::from_secs(60);
/// How long a git command gets.
const GIT_TIME: Duration = Duration::from_secs(300);

pub struct GitHub {
    http: Client,
    /// The REST API's root, and where repositories are cloned from:
    /// GitHub's, or a test's.
    api: String,
    git: String,
    login: String,
    token: String,
    /// One push or new pull request at a time, so that the day's count
    /// holds.
    one: Mutex<()>,
}

/// Where a push went.
#[derive(Debug, PartialEq, Eq)]
pub struct Pushed {
    /// Max's fork, or the repository itself if it is Max's.
    pub repo: String,
    /// What a pull request from it names as its head.
    pub head: String,
}

/// What the REST API answered.
#[derive(Debug, PartialEq, Eq)]
pub struct Reply {
    pub status: u16,
    /// Null when it answered nothing.
    pub body: Value,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// Not done as asked; the message says why, for the model.
    Refused(String),
    /// GitHub, or git, failed.
    Unavailable(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Refused(why) => write!(f, "{why}"),
            Self::Unavailable(why) => write!(f, "GitHub 暂时用不了：{why}"),
        }
    }
}

#[derive(Deserialize)]
struct Repo {
    full_name: String,
    default_branch: String,
    #[serde(default)]
    archived: bool,
    owner: User,
}

#[derive(Deserialize)]
struct User {
    login: String,
}

/// An issue, pull request or comment: who wrote it.
#[derive(Deserialize)]
struct Written {
    user: User,
}

#[derive(Deserialize)]
struct Found {
    total_count: u64,
}

/// What a write reaches, which decides whether Max may make it.
#[derive(Debug, PartialEq, Eq)]
enum Reach {
    /// A read, or a write to one of Max's own repositories.
    Free,
    /// Opens a pull request on `owner/name`.
    Open(String),
    /// Issue or pull request `number` of `owner/name`: Max's if it opened it.
    Thread(String, u64),
    /// A comment of `owner/name`, on an issue (`issues`) or on a pull
    /// request's diff (`pulls`): Max's if it wrote it.
    Comment(String, &'static str, u64),
}

impl GitHub {
    pub fn new(api: &str, git: &str, login: String, token: String) -> reqwest::Result<Self> {
        let http = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(60))
            .user_agent("maxx")
            .build()?;
        Ok(Self {
            http,
            api: api.to_owned(),
            git: git.to_owned(),
            login,
            token,
            one: Mutex::new(()),
        })
    }

    /// Calls the REST API at `path`, with its query if any, unless it
    /// writes what isn't Max's. A new pull request counts against the
    /// day's, and says under its description that an AI opened it; so does
    /// a description Max rewrites.
    pub async fn api(
        &self,
        method: Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<Reply, Error> {
        if !matches!(
            method,
            Method::GET | Method::POST | Method::PATCH | Method::PUT | Method::DELETE
        ) {
            return Err(Error::Refused(format!("不支持 {method}")));
        }
        if !path_ok(path) {
            return Err(Error::Refused(format!(
                "{path:?} 不是 REST API 的路径：以 / 开头，不能有 .. 和空白"
            )));
        }
        let mut body = body;
        let reach = self.reach(&method, path)?;
        let _one = match reach {
            Reach::Free => None,
            Reach::Open(ref repo) => {
                let one = self.one.lock().await;
                self.opening(repo, body.as_mut()).await?;
                Some(one)
            }
            Reach::Thread(ref repo, number) => {
                let written = format!("/repos/{repo}/issues/{number}");
                self.mine(&written, &format!("{repo}#{number}")).await?;
                let fields = path.split('?').next().unwrap_or(path).split('/').count();
                if method == Method::PATCH
                    && fields == 6
                    && let Some(Value::String(text)) =
                        body.as_mut().and_then(|body| body.get_mut("body"))
                    && !text.contains(FOOTER)
                {
                    *text = signed(text);
                }
                None
            }
            Reach::Comment(ref repo, kind, id) => {
                let written = format!("/repos/{repo}/{kind}/comments/{id}");
                self.mine(&written, &format!("这条评论（{id}）")).await?;
                None
            }
        };
        let (status, answer) = self.send(method.clone(), path, body).await?;
        if matches!(reach, Reach::Open(_)) && status.is_success() {
            info!(path, number = %answer["number"], "opened a pull request");
        }
        Ok(Reply {
            status: status.as_u16(),
            body: answer,
        })
    }

    /// What a call reaches, or why Max may not make it.
    fn reach(&self, method: &Method, path: &str) -> Result<Reach, Error> {
        if *method == Method::GET {
            return Ok(Reach::Free);
        }
        let route = path.split('?').next().unwrap_or(path);
        let segments: Vec<&str> = route.trim_start_matches('/').split('/').collect();
        let repo = |owner: &str, name: &str| format!("{owner}/{name}");
        let number = |text: &str| text.parse::<u64>().ok();
        let reach = match segments.as_slice() {
            ["repos", owner, ..] if owner.eq_ignore_ascii_case(&self.login) => Some(Reach::Free),
            ["repos", owner, name, "pulls"] if *method == Method::POST => {
                Some(Reach::Open(repo(owner, name)))
            }
            [
                "repos",
                owner,
                name,
                kind @ ("issues" | "pulls"),
                "comments",
                id,
                ..,
            ] => {
                let kind = if *kind == "issues" { "issues" } else { "pulls" };
                number(id).map(|id| Reach::Comment(repo(owner, name), kind, id))
            }
            ["repos", owner, name, "issues" | "pulls", thread, ..] => {
                number(thread).map(|thread| Reach::Thread(repo(owner, name), thread))
            }
            _ => None,
        };
        reach.ok_or_else(|| {
            Error::Refused(format!(
                "{method} {route} 不行：只能读，写只能写你自己的（你的仓库、你开的 PR 和 issue、你的评论），或者开 PR"
            ))
        })
    }

    /// Whether Max may open the pull request `body` asks for on `repo`:
    /// from its own branch, and within the day's. Signs its description.
    async fn opening(&self, repo: &str, body: Option<&mut Value>) -> Result<(), Error> {
        let Some(Value::Object(fields)) = body else {
            return Err(Error::Refused(
                "开 PR 要 body：{title, head, base, body}".into(),
            ));
        };
        let head = fields
            .get("head")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let ours = match head.split_once(':') {
            Some((owner, _)) => owner.eq_ignore_ascii_case(&self.login),
            None => repo
                .split('/')
                .next()
                .is_some_and(|owner| owner.eq_ignore_ascii_case(&self.login)),
        };
        if !ours {
            return Err(Error::Refused(format!(
                "head 要是你自己的分支，写成 {}:分支名，用 github_push 返回的",
                self.login
            )));
        }
        let made = self.made_today().await?;
        if made >= DAILY {
            return Err(Error::Refused(format!(
                "今天已经开了 {made} 个 PR，一天最多 {DAILY} 个，明天再开"
            )));
        }
        let text = fields
            .get("body")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let signed = signed(text);
        fields.insert("body".into(), Value::String(signed));
        Ok(())
    }

    /// Whether Max wrote what is at `path`, which is `what` to the model.
    async fn mine(&self, path: &str, what: &str) -> Result<(), Error> {
        let written: Written = match self.get(path).await? {
            Ok(written) => written,
            Err((StatusCode::NOT_FOUND, _)) => {
                return Err(Error::Refused(format!("{what} 不存在")));
            }
            Err((status, said)) => return Err(unavailable(status, &said)),
        };
        if written.user.login.eq_ignore_ascii_case(&self.login) {
            Ok(())
        } else {
            Err(Error::Refused(format!(
                "{what} 是 {} 的，不是你的：只能读",
                written.user.login
            )))
        }
    }

    /// Pushes the bundle's commits to `branch` of Max's fork of `repo`,
    /// forked if it has none, or of `repo` if it is Max's. The branch is
    /// replaced: an open pull request from it is updated.
    pub async fn push(&self, repo: &str, branch: &str, bundle: &[u8]) -> Result<Pushed, Error> {
        if !repo_name(repo) {
            return Err(Error::Refused(format!(
                "{repo:?} 不是 owner/name 这样的仓库名"
            )));
        }
        if !branch_name(branch) {
            return Err(Error::Refused(format!("{branch:?} 不能当分支名")));
        }
        let header = header(bundle).ok_or_else(|| {
            Error::Refused("这不是 git bundle：在仓库里用 git bundle create 打一个".into())
        })?;
        let _one = self.one.lock().await;
        let upstream: Repo = match self.get(&format!("/repos/{repo}")).await? {
            Ok(repo) => repo,
            Err((StatusCode::NOT_FOUND, _)) => {
                return Err(Error::Refused(format!("{repo} 不存在，或者不是公开仓库")));
            }
            Err((status, said)) => return Err(unavailable(status, &said)),
        };
        if upstream.archived {
            return Err(Error::Refused(format!(
                "{} 已经归档，不收 PR 了",
                upstream.full_name
            )));
        }
        let own = upstream.owner.login.eq_ignore_ascii_case(&self.login);
        let (target, head) = if own {
            if branch == upstream.default_branch {
                return Err(Error::Refused("不能推到默认分支，换一个分支名".into()));
            }
            (upstream.full_name.clone(), branch.to_owned())
        } else {
            let fork = self.fork(&upstream.full_name).await?;
            self.sync(&fork, &upstream.default_branch).await;
            (fork, format!("{}:{branch}", self.login))
        };
        self.git_push(&upstream.full_name, &target, branch, &header, bundle)
            .await?;
        info!(repo = target, branch, "pushed a branch");
        Ok(Pushed { repo: target, head })
    }

    /// The pull requests Max opened in the last 24 hours, anywhere.
    async fn made_today(&self) -> Result<u64, Error> {
        let since =
            (Utc::now() - chrono::Duration::hours(24)).to_rfc3339_opts(SecondsFormat::Secs, true);
        let query = format!("type:pr author:{} created:>={since}", self.login);
        let (status, answer) = self
            .send(
                Method::GET,
                "/search/issues",
                Some(json!({ "q": query, "per_page": 1 })),
            )
            .await?;
        if !status.is_success() {
            return Err(unavailable(status, &answer));
        }
        let found: Found = serde_json::from_value(answer)
            .map_err(|error| Error::Unavailable(error.to_string()))?;
        Ok(found.total_count)
    }

    /// Max's fork of `repo`, made if it has none, once GitHub has it.
    async fn fork(&self, repo: &str) -> Result<String, Error> {
        let (status, answer) = self
            .send(
                Method::POST,
                &format!("/repos/{repo}/forks"),
                Some(json!({})),
            )
            .await?;
        if matches!(
            status,
            StatusCode::FORBIDDEN | StatusCode::UNPROCESSABLE_ENTITY
        ) {
            return Err(Error::Refused(format!(
                "{repo} fork 不了：{}",
                message(&answer)
            )));
        }
        if !status.is_success() {
            return Err(unavailable(status, &answer));
        }
        let fork: Repo = serde_json::from_value(answer)
            .map_err(|error| Error::Unavailable(error.to_string()))?;
        let ready = Instant::now() + FORKING;
        loop {
            if self
                .get::<Value>(&format!("/repos/{}", fork.full_name))
                .await?
                .is_ok()
            {
                return Ok(fork.full_name);
            }
            if Instant::now() >= ready {
                return Err(Error::Unavailable(format!(
                    "{} 一分钟了还没 fork 好，等一会儿再推",
                    fork.full_name
                )));
            }
            sleep(Duration::from_secs(2)).await;
        }
    }

    /// Brings the fork's `branch` up to the upstream's, where it can be
    /// fast-forwarded: the push then sends only the new commits. Nothing
    /// depends on it.
    async fn sync(&self, fork: &str, branch: &str) {
        let synced = self
            .send(
                Method::POST,
                &format!("/repos/{fork}/merge-upstream"),
                Some(json!({ "branch": branch })),
            )
            .await;
        if let Ok((status, answer)) = synced
            && !status.is_success()
        {
            info!(fork, %status, "the fork's branch wasn't synced: {}", message(&answer));
        }
    }

    /// Takes the bundle into a bare repository of its own, with the
    /// commits it builds on fetched from `upstream`, and pushes it to
    /// `branch` in `target`.
    async fn git_push(
        &self,
        upstream: &str,
        target: &str,
        branch: &str,
        header: &Header,
        bundle: &[u8],
    ) -> Result<(), Error> {
        let scratch = Scratch::new().map_err(|error| Error::Unavailable(error.to_string()))?;
        let file = scratch.0.join("pr.bundle");
        tokio::fs::write(&file, bundle)
            .await
            .map_err(|error| Error::Unavailable(error.to_string()))?;
        let repo = scratch.0.join("repo.git");
        self.git(&scratch.0, &["init", "--quiet", "--bare", "repo.git"])
            .await
            .map_err(Error::Unavailable)?;
        if !header.prerequisites.is_empty() {
            let from = self.url(upstream);
            let mut args = vec!["fetch", "--quiet", "--depth=1", from.as_str()];
            args.extend(header.prerequisites.iter().map(String::as_str));
            self.git(&repo, &args).await.map_err(|why| {
                Error::Refused(format!(
                    "bundle 里的提交所基于的 {} 在 {upstream} 里找不到：在它的分支上提交，打包时用 --not --remotes（{why}）",
                    header.prerequisites.join("、")
                ))
            })?;
        }
        let file = file.display().to_string();
        let taken = format!("{}:refs/heads/{branch}", header.head);
        self.git(
            &repo,
            &[
                "-c",
                "fetch.fsckObjects=true",
                "fetch",
                "--quiet",
                &file,
                &taken,
            ],
        )
        .await
        .map_err(|why| Error::Refused(format!("bundle 打不开：{why}")))?;
        let to = self.url(target);
        let refspec = format!("refs/heads/{branch}:refs/heads/{branch}");
        self.git(&repo, &["push", "--quiet", "--force", &to, &refspec])
            .await
            .map_err(|why| Error::Unavailable(format!("推不到 {target}：{why}")))
    }

    fn url(&self, repo: &str) -> String {
        format!("{}/{repo}.git", self.git)
    }

    /// Runs git in `dir`, with none of the host's or the user's
    /// configuration, and the token for GitHub's HTTPS. Its error is what
    /// it said, cut short.
    async fn git(&self, dir: &Path, args: &[&str]) -> Result<(), String> {
        let credentials = STANDARD.encode(format!("{}:{}", self.login, self.token));
        let mut command = Command::new("git");
        command
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_TERMINAL_PROMPT", "0")
            .env("HOME", dir)
            .env("GIT_CONFIG_COUNT", "1")
            .env(
                "GIT_CONFIG_KEY_0",
                format!("http.{}/.extraHeader", self.git),
            )
            .env(
                "GIT_CONFIG_VALUE_0",
                format!("Authorization: Basic {credentials}"),
            )
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        let output = match timeout(GIT_TIME, command.output()).await {
            Ok(Ok(output)) => output,
            Ok(Err(error)) => {
                warn!(%error, "couldn't run git");
                return Err(format!("git 跑不起来：{error}"));
            }
            Err(_) => return Err("git 五分钟没跑完".into()),
        };
        if output.status.success() {
            return Ok(());
        }
        let said = String::from_utf8_lossy(&output.stderr);
        let said = said.trim();
        let start = said.char_indices().rev().nth(399).map_or(0, |(at, _)| at);
        Err(said[start..].to_owned())
    }

    /// GETs `path`: what it is, or the status and what GitHub said.
    async fn get<T: DeserializeOwned>(
        &self,
        path: &str,
    ) -> Result<Result<T, (StatusCode, Value)>, Error> {
        let (status, answer) = self.send(Method::GET, path, None).await?;
        if !status.is_success() {
            return Ok(Err((status, answer)));
        }
        serde_json::from_value(answer)
            .map(Ok)
            .map_err(|error| Error::Unavailable(error.to_string()))
    }

    /// Sends a request to the REST API: a GET's `body` is its query.
    async fn send(
        &self,
        method: Method,
        path: &str,
        body: Option<Value>,
    ) -> Result<(StatusCode, Value), Error> {
        let unavailable = |error: reqwest::Error| Error::Unavailable(error.to_string());
        let get = method == Method::GET;
        let mut url = Url::parse(&format!("{}{path}", self.api))
            .map_err(|error| Error::Refused(format!("{path:?} 不是路径：{error}")))?;
        if get && let Some(Value::Object(query)) = &body {
            let mut pairs = url.query_pairs_mut();
            for (key, value) in query {
                match value {
                    Value::String(text) => pairs.append_pair(key, text),
                    value => pairs.append_pair(key, &value.to_string()),
                };
            }
        }
        let mut request = self
            .http
            .request(method, url)
            .bearer_auth(&self.token)
            .header("accept", "application/vnd.github+json")
            .header("x-github-api-version", "2022-11-28");
        if let Some(body) = body
            && !get
        {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(unavailable)?;
        let status = response.status();
        let text = response.text().await.map_err(unavailable)?;
        let answer = if text.trim().is_empty() {
            Value::Null
        } else {
            serde_json::from_str(&text).unwrap_or(Value::String(text))
        };
        Ok((status, answer))
    }
}

/// A description with the footer under it.
fn signed(text: &str) -> String {
    let text = text.trim_end();
    if text.is_empty() {
        FOOTER.to_owned()
    } else {
        format!("{text}\n\n{FOOTER}")
    }
}

fn unavailable(status: StatusCode, said: &Value) -> Error {
    let said = message(said);
    warn!(%status, "GitHub said no: {said}");
    let why = match status {
        StatusCode::UNAUTHORIZED => "token 不对或者过期了".to_owned(),
        StatusCode::FORBIDDEN | StatusCode::TOO_MANY_REQUESTS => {
            format!("被限流或者拒绝了：{said}")
        }
        status => format!("HTTP {}：{said}", status.as_u16()),
    };
    Error::Unavailable(why)
}

/// GitHub's error, with the details it lists.
fn message(said: &Value) -> String {
    let mut parts: Vec<String> = said["message"]
        .as_str()
        .map(str::to_owned)
        .into_iter()
        .collect();
    for error in said["errors"].as_array().into_iter().flatten() {
        match error["message"].as_str() {
            Some(message) => parts.push(message.to_owned()),
            None => parts.push(error.to_string()),
        }
    }
    parts.join("; ").chars().take(400).collect()
}

/// A path of the REST API, with its query if any.
fn path_ok(path: &str) -> bool {
    let route = path.split('?').next().unwrap_or(path);
    path.starts_with('/')
        && path.len() <= 500
        && !path.contains(|char: char| char.is_whitespace() || char == '#')
        && route.bytes().all(|byte| {
            byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'-' | b'_' | b'.' | b'~')
        })
        && !route.contains("..")
        && !route.contains("//")
}

/// A bundle's header: the commits it builds on, and the ref that holds
/// what it brings, `HEAD` if it has that.
#[derive(Debug, PartialEq, Eq)]
struct Header {
    prerequisites: Vec<String>,
    head: String,
}

fn header(bundle: &[u8]) -> Option<Header> {
    let end = bundle.windows(2).position(|pair| pair == b"\n\n")?;
    let text = std::str::from_utf8(&bundle[..end]).ok()?;
    let mut lines = text.lines();
    if !matches!(lines.next()?, "# v2 git bundle" | "# v3 git bundle") {
        return None;
    }
    let hex =
        |id: &str| matches!(id.len(), 40 | 64) && id.bytes().all(|byte| byte.is_ascii_hexdigit());
    let mut prerequisites = Vec::new();
    let mut refs = Vec::new();
    for line in lines {
        if line.starts_with('@') {
            continue;
        }
        if let Some(prerequisite) = line.strip_prefix('-') {
            let id = prerequisite.split(' ').next()?;
            if !hex(id) {
                return None;
            }
            prerequisites.push(id.to_owned());
        } else {
            let (id, name) = line.split_once(' ')?;
            if !hex(id)
                || !(name == "HEAD" || name.starts_with("refs/"))
                || name.contains([' ', ':'])
            {
                return None;
            }
            refs.push(name.to_owned());
        }
    }
    let head = if refs.iter().any(|name| name == "HEAD") {
        "HEAD".to_owned()
    } else {
        refs.into_iter().next()?
    };
    Some(Header {
        prerequisites,
        head,
    })
}

/// `owner/name`, as GitHub allows them.
fn repo_name(repo: &str) -> bool {
    let Some((owner, name)) = repo.split_once('/') else {
        return false;
    };
    (1..=39).contains(&owner.len())
        && owner
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        && (1..=100).contains(&name.len())
        && !matches!(name, "." | "..")
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

/// A branch name git takes, kept to plain characters.
fn branch_name(branch: &str) -> bool {
    (1..=100).contains(&branch.len())
        && branch
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'/'))
        && !branch.starts_with(['-', '/', '.'])
        && !branch.ends_with(['/', '.'])
        && !branch.ends_with(".lock")
        && !branch.contains("..")
        && !branch.contains("//")
        && !branch.contains("/.")
}

/// A scratch directory, gone when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> std::io::Result<Self> {
        let dir = std::env::temp_dir().join(format!("maxx-pr-{:016x}", rand::random::<u64>()));
        std::fs::create_dir(&dir)?;
        Ok(Self(dir))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
