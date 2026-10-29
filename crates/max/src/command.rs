//! Commands: a message that starts with `/` and a word from this list.
//! Only `/`: QQ's command panel fills one in, and `!` is plain text. There
//! is no `/help`: the panel is the list.
//! The conversation actor runs them; they never reach a core. Their
//! answers read like a log, in a code block: see `answer`.

/// A command and its argument, parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    Status,
    Kill,
    /// `/model`, `/model list`, or `/model <provider/model>`.
    Model(Option<String>),
    /// `/effort`, `/effort default`, or `/effort <level>`.
    Effort(Option<String>),
    /// `/proactive`, or on, off, default.
    Proactive(Option<bool>),
    Persona(Persona),
    /// `/clear --all`; a bare `/clear` is answered with how.
    Clear {
        all: bool,
    },
    /// `/compact`: summarize what was said, up to now.
    Compact,
    /// `/bind`, `/bind <legacy group>` in a private chat, `/bind <code>` in
    /// a group.
    Bind(Option<String>),
    /// `/link <QQ号>`, or an owner's `/link @某人 <QQ号>` and
    /// `/link @某人 -`.
    Link(Option<String>),
}

impl Command {
    /// The word it is run by.
    pub fn name(&self) -> &'static str {
        match self {
            Command::Status => "status",
            Command::Kill => "kill",
            Command::Model(_) => "model",
            Command::Effort(_) => "effort",
            Command::Proactive(_) => "proactive",
            Command::Persona(_) => "persona",
            Command::Clear { .. } => "clear",
            Command::Compact => "compact",
            Command::Bind(_) => "bind",
            Command::Link(_) => "link",
        }
    }
}

/// A command's answer as it is said: `/name → result`, any more lines
/// under it, in a text code block, set apart from what Max says in a
/// turn. The fence outgrows any run of backticks inside, as a persona
/// may have.
pub fn answer(name: &str, body: &str) -> String {
    let longest = body.split(|c| c != '`').map(str::len).max().unwrap_or(0);
    let fence = "`".repeat(longest.max(2) + 1);
    format!("{fence}text\n/{name} → {body}\n{fence}")
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Persona {
    Show,
    Reset,
    Set(String),
}

/// None for anything else, such as `/nix/store`, `!help` or an unknown
/// word: that is chatter, not a command.
pub fn parse(text: &str) -> Option<Command> {
    let rest = text.trim().strip_prefix(['/', '／'])?;
    let (word, argument) = match rest.split_once(char::is_whitespace) {
        Some((word, argument)) => (word, argument.trim()),
        None => (rest, ""),
    };
    let argument = (!argument.is_empty()).then(|| argument.to_owned());
    Some(match word.to_lowercase().as_str() {
        "status" => Command::Status,
        "kill" => Command::Kill,
        "model" => Command::Model(argument),
        "effort" => Command::Effort(argument),
        "proactive" => Command::Proactive(match argument.as_deref() {
            None => None,
            Some("on" | "default") => Some(true),
            Some("off") => Some(false),
            Some(_) => return None,
        }),
        "persona" => Command::Persona(match argument {
            None => Persona::Show,
            Some(text) if text == "clear" || text == "reset" => Persona::Reset,
            Some(text) => Persona::Set(text),
        }),
        "clear" => Command::Clear {
            all: argument.as_deref() == Some("--all"),
        },
        "compact" => Command::Compact,
        "bind" => Command::Bind(argument),
        "link" => Command::Link(argument),
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn commands_and_not() {
        assert_eq!(parse(" ／Status "), Some(Command::Status));
        assert_eq!(
            parse("/model test/big"),
            Some(Command::Model(Some("test/big".into())))
        );
        assert_eq!(parse("/effort"), Some(Command::Effort(None)));
        assert_eq!(
            parse("/proactive off"),
            Some(Command::Proactive(Some(false)))
        );
        assert_eq!(parse("/proactive maybe"), None);
        assert_eq!(
            parse("/persona 你是一只猫。\n说话带喵"),
            Some(Command::Persona(Persona::Set(
                "你是一只猫。\n说话带喵".into()
            )))
        );
        assert_eq!(
            parse("/persona clear"),
            Some(Command::Persona(Persona::Reset))
        );
        assert_eq!(parse("/clear"), Some(Command::Clear { all: false }));
        assert_eq!(parse("/clear --all"), Some(Command::Clear { all: true }));
        assert_eq!(parse("/compact"), Some(Command::Compact));
        assert_eq!(
            parse("/bind 123456"),
            Some(Command::Bind(Some("123456".into())))
        );
        for chatter in [
            "/help",
            "!status",
            "！status",
            "/",
            "///",
            "/ ls",
            "/nix/store/abc",
            "kill",
            "/killall",
            "",
        ] {
            assert_eq!(parse(chatter), None, "{chatter:?}");
        }
    }

    #[test]
    fn answers_are_code_blocks() {
        assert_eq!(answer("clear", "已清空"), "```text\n/clear → 已清空\n```");
        let persona = "当前人设：\n用 ```python 写代码";
        assert_eq!(
            answer("persona", persona),
            format!("````text\n/persona → {persona}\n````")
        );
    }
}
