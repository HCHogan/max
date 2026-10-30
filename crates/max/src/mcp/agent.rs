//! `agent`, `agent_steer`, `agent_cancel` and `agent_status`: the
//! background agents, which the conversation's actor keeps. See "后台
//! agent" in docs/rust-rewrite.md.

use serde::Deserialize;
use serde_json::Value;

use super::{Context, Failure, arguments};
use crate::job::Request;

pub const NAMES: [&str; 4] = ["agent", "agent_steer", "agent_cancel", "agent_status"];

/// A title's most characters, as the tool's schema says.
const TITLE: usize = 40;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Start {
    task: String,
    title: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Steer {
    job: Job,
    message: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Which {
    job: Job,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Status {
    job: Option<Job>,
}

/// `job#3`, `3` or 3.
#[derive(Deserialize)]
#[serde(untagged)]
enum Job {
    Number(u32),
    Text(String),
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

pub async fn run(name: &str, context: &Context, args: Value) -> Result<Value, Failure> {
    let request = match name {
        "agent" => start(args)?,
        "agent_steer" => {
            let Steer { job, message } = arguments(name, args)?;
            if message.trim().is_empty() {
                return Err(Failure::new("bad_arguments", "message 是空的"));
            }
            Request::Steer {
                job: job.number()?,
                message,
            }
        }
        "agent_cancel" => {
            let Which { job } = arguments(name, args)?;
            Request::Cancel { job: job.number()? }
        }
        _ => {
            let Status { job } = arguments(name, args)?;
            Request::Status {
                job: job.map(Job::number).transpose()?,
            }
        }
    };
    // Only a turn's programs have their conversation at hand.
    let Some(poster) = context.caller.poster() else {
        return Err(Failure::new("not_here", "这里管不了后台 agent"));
    };
    poster
        .jobs(request)
        .await
        .map_err(|message| Failure::new("job", message))
}

fn start(args: Value) -> Result<Request, Failure> {
    let Start { task, title } = arguments("agent", args)?;
    if task.trim().is_empty() {
        return Err(Failure::new("bad_arguments", "task 是空的"));
    }
    if title
        .as_ref()
        .is_some_and(|title| title.chars().count() > TITLE)
    {
        return Err(Failure::new(
            "bad_arguments",
            format!("title 最多 {TITLE} 个字"),
        ));
    }
    Ok(Request::Start { task, title })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_title_is_at_most_forty_characters() {
        let title = |title: String| start(serde_json::json!({ "task": "查票价", "title": title }));
        assert!(title("票".repeat(TITLE)).is_ok());
        assert_eq!(
            title("票".repeat(TITLE + 1)).unwrap_err().code,
            "bad_arguments"
        );
        assert!(
            max_core::tools::MAX_TOOLS
                .iter()
                .any(|tool| tool.name == "agent"
                    && tool.input.contains(&format!("\"maxLength\":{TITLE}")))
        );
    }

    #[test]
    fn a_job_is_named_either_way() {
        let job = |value: Value| serde_json::from_value::<Job>(value).unwrap().number();
        assert_eq!(job(serde_json::json!("job#3")).unwrap(), 3);
        assert_eq!(job(serde_json::json!(" 3 ")).unwrap(), 3);
        assert_eq!(job(serde_json::json!(3)).unwrap(), 3);
        assert_eq!(
            job(serde_json::json!("三")).unwrap_err().code,
            "bad_arguments"
        );
    }
}
