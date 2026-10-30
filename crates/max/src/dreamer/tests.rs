use std::sync::Arc;

use sqlx::PgPool;

use super::*;
use crate::conversation::testing::{group, offset};
use crate::llm::testing::{Answer, Script, models};

/// A scratch VMs' directory, gone when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("max-dreamer-{:016x}", rand::random::<u64>()));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    /// The conversation's memory file, written `ago` before now.
    fn memory(&self, conversation: ConversationId, text: &str, ago: Duration) -> PathBuf {
        let dir = vm::work(&self.0, conversation).join(".max");
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("memory.md");
        std::fs::write(&file, text).unwrap();
        let written = std::fs::File::options().write(true).open(&file).unwrap();
        written.set_modified(SystemTime::now() - ago).unwrap();
        file
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const OLD: &str = "## 群里\n- 叫我鲨鲨（2026-10-01 #5）\n- 叫我鲨鲨（2026-10-20 #9）\n- 10-25 前别催更（2026-10-10 #7）\n\n## 人\n";
const NEW: &str = "## 群里\n- 叫我鲨鲨（2026-10-20 #5 #9）\n\n## 人";

#[test]
fn the_night_is_five_local() {
    let at = |text: &str| {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .with_timezone(&Utc)
    };
    let hours = |text| until_night(at(text), offset()).as_secs_f64() / 3600.0;
    assert_eq!(hours("2026-10-30T04:00:00+08:00"), 1.0);
    assert_eq!(hours("2026-10-30T05:00:00+08:00"), 24.0);
    assert_eq!(hours("2026-10-30T23:30:00+08:00"), 5.5);
}

#[test]
fn what_the_model_wrote_is_a_file_or_refused() {
    assert_eq!(tidied(NEW, OLD).unwrap(), format!("{NEW}\n"));
    let fenced = format!("```markdown\n{NEW}\n```");
    assert_eq!(tidied(&fenced, OLD).unwrap(), format!("{NEW}\n"));
    assert!(tidied("整理好了。", OLD).is_err());
    let long = "- 一条很长的记忆，后面还有很多字。\n".repeat(40);
    assert!(tidied("## 群里\n- 一条", &format!("## 群里\n{long}")).is_err());
}

#[sqlx::test(migrator = "max_db::MIGRATOR")]
async fn a_file_written_since_is_tidied_and_keeps_its_time(pool: PgPool) {
    let mut conn = pool.acquire().await.unwrap();
    let conversation = group(&mut conn).await.conversation;
    let untouched = crate::conversation::testing::group_named(&mut conn, "group:GROUP2")
        .await
        .conversation;
    drop(conn);
    let scratch = Scratch::new();
    let hour = Duration::from_secs(3600);
    let file = scratch.memory(conversation, OLD, hour);
    let stale = scratch.memory(untouched, OLD, 30 * hour);
    let script = Arc::new(Script::default());
    let dreamer = Dreamer {
        pool: pool.clone(),
        chosen: models(&script).choose("test/big", None).unwrap(),
        dir: scratch.0.clone(),
        offset: offset(),
    };
    let since = SystemTime::now() - 24 * hour;

    // Written a day and more ago: the night before had it.
    assert_eq!(dreamer.tidy(untouched, since).await.unwrap(), None);
    assert_eq!(std::fs::read_to_string(&stale).unwrap(), OLD);
    assert_eq!(script.calls(), 0);

    let written = std::fs::metadata(&file).unwrap().modified().unwrap();
    script.push(Answer::says(NEW));
    assert_eq!(
        dreamer.tidy(conversation, since).await.unwrap(),
        Some((6, 4))
    );
    assert_eq!(std::fs::read_to_string(&file).unwrap(), format!("{NEW}\n"));
    let before = file.with_file_name(BEFORE);
    assert_eq!(std::fs::read_to_string(&before).unwrap(), OLD);
    assert_eq!(
        std::fs::metadata(&file).unwrap().modified().unwrap(),
        written
    );
    let sent = script.requests.lock().unwrap()[0].items[1].kind.clone();
    let ItemKind::User { text, .. } = sent else {
        panic!("no user item");
    };
    assert!(text.starts_with("[现在] ") && text.ends_with(OLD), "{text}");
    let mut conn = pool.acquire().await.unwrap();
    let purposes: Vec<String> = sqlx::query_scalar("select purpose from llm_usage")
        .fetch_all(&mut *conn)
        .await
        .unwrap();
    assert_eq!(purposes, ["dreamer"]);

    // What isn't a file is refused, and the file stays.
    scratch.memory(conversation, OLD, hour);
    script.push(Answer::says("整理好了。"));
    assert!(dreamer.tidy(conversation, since).await.is_err());
    assert_eq!(std::fs::read_to_string(&file).unwrap(), OLD);
}
