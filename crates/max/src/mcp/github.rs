//! `github` and `github_push`: Max's GitHub account, through the host,
//! which holds its token and decides what Max may write. See "GitHub" in
//! docs/rust-rewrite.md.

use reqwest::Method;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use tokio::task::spawn_blocking;

use super::tool::Tool;
use super::work::{beneath_work, read};
use super::{Context, Failure, internal};
use crate::github::{DAILY, Error, Pushed};

/// The most a reply's body holds, in characters of JSON; past it the
/// program gets the text, cut short.
const LONGEST: usize = 30_000;
/// The largest bundle.
const MOST: u64 = 64 << 20;

pub struct GitHubApi;

#[derive(Deserialize, JsonSchema)]
#[serde(rename_all = "UPPERCASE")]
pub enum Verb {
    Get,
    Post,
    Patch,
    Put,
    Delete,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ApiArgs {
    #[schemars(description = "GET、POST、PATCH、PUT 或 DELETE")]
    method: Verb,
    #[schemars(
        length(min = 2, max = 500),
        description = "REST API 的路径，可以带查询参数，比如 /repos/octo/hello/pulls?state=open"
    )]
    path: String,
    #[schemars(description = "请求的 JSON；GET 的是查询参数")]
    body: Option<Map<String, Value>>,
}

#[derive(Serialize, JsonSchema)]
pub struct Answered {
    status: u16,
    body: Body,
}

#[derive(Serialize, JsonSchema)]
#[serde(untagged)]
pub enum Body {
    Object(Map<String, Value>),
    List(Vec<Map<String, Value>>),
    /// Not a JSON object or a list of them, or too long: the text.
    Text(String),
    Nothing(()),
}

impl Tool for GitHubApi {
    const NAME: &'static str = "github";
    const DESCRIPTION: &'static str = "用 Max 的 GitHub 账号调 REST API：读什么都行；写只能写 Max 自己的（它的仓库、它开的 PR 和 issue、它的评论），或者开 PR（POST /repos/{owner}/{repo}/pulls，head 用 github_push 返回的，只在被要求时开）。";
    const PER_RUN: Option<u32> = Some(30);
    const JOB: bool = true;

    type Args = ApiArgs;
    type Output = Answered;

    fn guide() -> String {
        format!(
            "用你的 GitHub 账号调 REST API，返回 {{status, body}}。读什么都行：PR、review、评论、CI 的结果。写只能写你自己的：你的仓库、你开的 PR 和 issue、你写的评论；别人的只能读，也不能开 issue。\n  \
            开 PR：先用 github_push 把提交推上去，再 POST /repos/{{owner}}/{{repo}}/pulls，body 是 {{title, head, base, body}}，head 填 github_push 返回的。只在有人要你开 PR 时开，所有群加起来一天最多 {DAILY} 个新 PR；描述末尾会自动加一行，说明是 AI 开的。标题和描述用仓库自己的语言（多半是英文），写清楚改了什么、为什么、怎么验证的。\n  \
            之后：要改代码，在同一个分支上接着提交，再 github_push 一次；改标题、描述，或者关掉、重开，PATCH /repos/{{owner}}/{{repo}}/pulls/{{number}}，比如 {{state: \"closed\"}}；评论 POST /repos/{{owner}}/{{repo}}/issues/{{number}}/comments；回复 review 里的一条，POST /repos/{{owner}}/{{repo}}/pulls/{{number}}/comments/{{id}}/replies。"
        )
    }

    async fn run(
        context: &Context,
        ApiArgs { method, path, body }: ApiArgs,
    ) -> Result<Answered, Failure> {
        let Some(github) = &context.services.github else {
            return Err(unconfigured());
        };
        let method = match method {
            Verb::Get => Method::GET,
            Verb::Post => Method::POST,
            Verb::Patch => Method::PATCH,
            Verb::Put => Method::PUT,
            Verb::Delete => Method::DELETE,
        };
        let reply = github
            .api(method, &path, body.map(Value::Object))
            .await
            .map_err(failure)?;
        Ok(Answered {
            status: reply.status,
            body: shown(reply.body),
        })
    }
}

pub struct GitHubPush;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PushArgs {
    #[schemars(length(min = 3, max = 140), description = "上游仓库，owner/name")]
    repo: String,
    #[schemars(
        length(min = 1, max = 100),
        description = "推到你那边的哪个分支；同一个分支再推，它的 PR 就跟着更新"
    )]
    branch: String,
    #[schemars(length(min = 1), description = "git bundle 文件，/work 下的路径")]
    bundle: String,
}

#[derive(Serialize, JsonSchema)]
pub struct PushedTo {
    repo: String,
    head: String,
}

impl Tool for GitHubPush {
    const NAME: &'static str = "github_push";
    const DESCRIPTION: &'static str = "把 /work 里一个仓库的新提交推到 Max 在 GitHub 上的 fork，返回开 PR 要用的 head：先 commit，再在仓库里 git bundle create /work/名字.bundle HEAD --not --remotes，把 bundle 交给它。同一个分支再推，它的 PR 就跟着更新。";
    const PER_RUN: Option<u32> = Some(3);
    const JOB: bool = true;

    type Args = PushArgs;
    type Output = PushedTo;

    fn guide() -> String {
        "把 /work 里一个仓库的新提交推到你在 GitHub 上的 fork（没有就先 fork），返回 {repo, head}，head 是开 PR 时要填的。\n  \
        先在仓库里 git commit（作者已经设成你的账号），再在仓库里跑 git bundle create /work/名字.bundle HEAD --not --remotes，把这个文件交给它。分支会被整个换掉：在同一个分支上接着提交或者 amend，再打包推一次，它的 PR 就更新了。上游变了，先 git pull --rebase 再打包。"
            .to_owned()
    }

    async fn run(
        context: &Context,
        PushArgs {
            repo,
            branch,
            bundle,
        }: PushArgs,
    ) -> Result<PushedTo, Failure> {
        let (Some(work), Some(github)) = (&context.work, &context.services.github) else {
            return Err(unconfigured());
        };
        let relative = beneath_work(&bundle)?;
        let work = work.clone();
        let bytes = spawn_blocking(move || read(&work, &relative, MOST))
            .await
            .map_err(|_| internal())??;
        let Pushed { repo, head } = github
            .push(repo.trim(), branch.trim(), &bytes)
            .await
            .map_err(failure)?;
        Ok(PushedTo { repo, head })
    }
}

fn unconfigured() -> Failure {
    Failure::new("unavailable", "这里没有配 GitHub 账号。")
}

fn failure(error: Error) -> Failure {
    match error {
        Error::Refused(why) => Failure::new("refused", why),
        Error::Unavailable(_) => Failure::new("unavailable", error.to_string()),
    }
}

/// A reply's body as the program gets it: JSON while it is short.
fn shown(body: Value) -> Body {
    let text = body.to_string();
    let length = text.chars().count();
    if length > LONGEST {
        let cut: String = text.chars().take(LONGEST).collect();
        return Body::Text(format!(
            "{cut}…（截断了，原文 {length} 字：分页用 per_page、page，或者读更具体的路径）"
        ));
    }
    match body {
        Value::Null => Body::Nothing(()),
        Value::Object(fields) => Body::Object(fields),
        Value::Array(items) if items.iter().all(Value::is_object) => Body::List(
            items
                .into_iter()
                .filter_map(|item| match item {
                    Value::Object(fields) => Some(fields),
                    _ => None,
                })
                .collect(),
        ),
        Value::String(text) => Body::Text(text),
        _ => Body::Text(text),
    }
}
