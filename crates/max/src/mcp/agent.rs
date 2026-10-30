//! `agent`, `agent_steer`, `agent_cancel` and `agent_status`: the
//! background agents, which the conversation's actor keeps. See "后台
//! agent" in docs/rust-rewrite.md.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use super::tool::Tool;
use super::{Context, Failure, internal};
use crate::job::{self, Reply, Request};

/// A title's most characters.
const TITLE: usize = 40;
/// Jobs one run may start.
const PER_RUN: u32 = 3;

pub struct Agent;
pub struct AgentSteer;
pub struct AgentCancel;
pub struct AgentStatus;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Start {
    #[schemars(length(min = 1), description = "要它做的事，连同背景，写全")]
    task: String,
    #[schemars(length(max = TITLE), description = "一句话的标题")]
    title: Option<String>,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Steer {
    #[schemars(description = "job#3 或 3")]
    job: Job,
    #[schemars(length(min = 1))]
    message: String,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Which {
    #[schemars(description = "job#3 或 3")]
    job: Job,
}

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Status {
    #[schemars(description = "job#3 或 3；不填是全部")]
    job: Option<Job>,
}

/// `job#3`, `3` or 3.
#[derive(Deserialize, JsonSchema)]
#[serde(untagged)]
enum Job {
    Text(String),
    Number(u32),
}

/// The job a request was about.
#[derive(Serialize, JsonSchema)]
pub struct Named {
    job: String,
}

#[derive(Serialize, JsonSchema)]
pub struct Running {
    jobs: Vec<job::Status>,
}

impl Tool for Agent {
    const NAME: &'static str = "agent";
    const DESCRIPTION: &'static str = "交给一个后台 agent 去做一件要花时间的事，马上返回 job 编号；它做完了，报告作为 [job#N 完成] 回到你这里。";
    const PER_RUN: Option<u32> = Some(PER_RUN);
    const JOB: bool = false;

    type Args = Start;
    type Output = Named;

    fn guide() -> String {
        format!(
            "起一个后台 agent，去做一件要花时间的事：查一堆资料、读很多网页或文件、写代码跑实验。它在本群的 VM 里跑，和你共用 /work，自己有 shell、读写文件、history、web_search；不能在群里说话，也不能发图发文件、撤回、禁言。\n  \
            它看不到群里的对话，只看得到 task，所以背景、要做什么、做到什么程度、报告要写什么都写进去。title 是一句话的标题，agent_status 里显示。\n  \
            马上返回 {{ job: \"job#3\" }}，你接着聊。它卡在只有你或群友才知道的事上会问你：问题作为 [job#3 问] 出现，它在等，用 agent_steer 回答。它做完了，报告作为 [job#3 完成] 出现在你的新消息里，全文另存在 /work/.max/jobs/ 下，由你决定在群里怎么说。同时最多 {} 个，每个最多 {} 小时，到点停下、交出做到一半的结果。一次运行最多起 {PER_RUN} 个。",
            job::MOST,
            job::TIME.as_secs() / 3600,
        )
    }

    async fn run(context: &Context, Start { task, title }: Start) -> Result<Named, Failure> {
        if task.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "task 是空的"));
        }
        named(context, Request::Start { task, title }).await
    }
}

impl Tool for AgentSteer {
    const NAME: &'static str = "agent_steer";
    const DESCRIPTION: &'static str =
        "给还在跑的后台 agent 补一句话：改方向、补信息，或者回答它的 [job#N 问]。";
    const PER_RUN: Option<u32> = None;
    const JOB: bool = false;

    type Args = Steer;
    type Output = Named;

    fn guide() -> String {
        format!(
            "给还在跑的后台 agent 补一句话：改方向、补充信息、转达群友的回答。它跑完手上这步工具、下一次想之前看到。job 是 \"job#3\" 或 3。\n  \
            它问了你（[job#3 问]）还没得到答复时，下一句就是答复，它马上收到。你答不了就去群里问，问到了再转给它；{} 分钟内没答复，它就自己判断着做下去，之后再说的照常当补充。",
            job::WAIT.as_secs() / 60,
        )
    }

    async fn run(context: &Context, Steer { job, message }: Steer) -> Result<Named, Failure> {
        if message.trim().is_empty() {
            return Err(Failure::new("bad_arguments", "message 是空的"));
        }
        let job = job.number()?;
        named(context, Request::Steer { job, message }).await
    }
}

impl Tool for AgentCancel {
    const NAME: &'static str = "agent_cancel";
    const DESCRIPTION: &'static str = "停掉一个后台 agent，不要它的结果了。";
    const PER_RUN: Option<u32> = None;
    const JOB: bool = false;

    type Args = Which;
    type Output = Named;

    fn guide() -> String {
        "停掉一个后台 agent，不要它的结果了；它在 /work 里留下的东西还在。".into()
    }

    async fn run(context: &Context, Which { job }: Which) -> Result<Named, Failure> {
        let job = job.number()?;
        named(context, Request::Cancel { job }).await
    }
}

impl Tool for AgentStatus {
    const NAME: &'static str = "agent_status";
    const DESCRIPTION: &'static str =
        "看还在跑的后台 agent：标题、跑了几分钟、调了几次模型和工具、最近用的工具。";
    const PER_RUN: Option<u32> = None;
    const JOB: bool = false;

    type Args = Status;
    type Output = Running;

    fn guide() -> String {
        "看还在跑的后台 agent：标题、跑了几分钟、调了几次模型（calls）和工具（tools）、最近用的工具。job 不填就是全部；做完的、停掉的不在里面。".into()
    }

    async fn run(context: &Context, Status { job }: Status) -> Result<Running, Failure> {
        let job = job.map(Job::number).transpose()?;
        match ask(context, Request::Status { job }).await? {
            Reply::Running(jobs) => Ok(Running { jobs }),
            Reply::Job(_) => Err(internal()),
        }
    }
}

impl Job {
    fn number(self) -> Result<u32, Failure> {
        match self {
            Job::Number(number) => Ok(number),
            Job::Text(text) => {
                let digits = text.trim().trim_start_matches("job#");
                digits.parse().map_err(|_| {
                    Failure::new(
                        "bad_arguments",
                        format!("{text} 不是 job 的编号，要 job#3 或 3"),
                    )
                })
            }
        }
    }
}

/// The job `request` was about.
async fn named(context: &Context, request: Request) -> Result<Named, Failure> {
    match ask(context, request).await? {
        Reply::Job(job) => Ok(Named {
            job: job::name(job),
        }),
        Reply::Running(_) => Err(internal()),
    }
}

async fn ask(context: &Context, request: Request) -> Result<Reply, Failure> {
    // Only a turn's programs have their conversation at hand.
    let Some(poster) = context.caller.poster() else {
        return Err(Failure::new("not_here", "这里管不了后台 agent"));
    };
    poster
        .jobs(request)
        .await
        .map_err(|message| Failure::new("job", message))
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::*;

    #[test]
    fn a_job_is_named_either_way() {
        let job = |value: Value| serde_json::from_value::<Job>(value).unwrap().number();
        assert_eq!(job(json!("job#3")).unwrap(), 3);
        assert_eq!(job(json!(" 3 ")).unwrap(), 3);
        assert_eq!(job(json!(3)).unwrap(), 3);
        assert_eq!(job(json!("三")).unwrap_err().code, "bad_arguments");
    }
}
