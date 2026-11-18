//! Commands: a message that starts with `/` and a word from this list,
//! in a group only with Max @-mentioned, since other bots there take `/`
//! commands too. Only `/`: QQ's command panel fills one in, and `!` is
//! plain text. There is no `/help`: the panel is the list.
//! The conversation actor runs them; they never reach a core. Their
//! answers read like a log, in English, in a code block: see `answer`.

use std::str::FromStr;

use max_db::platform::ConversationKind;

use crate::inbound::Inbound;

/// A command and its argument, parsed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    /// `/status`: how Max is here.
    Status,
    /// `/kill`: ends the running turn.
    Kill,
    /// `/stop`: Max records messages but doesn't reply, until `/start`.
    Stop,
    /// `/start`: Max replies again.
    Start,
    /// `/model` or `/model list`, which show the models, or `/model
    /// <provider/model>`.
    Model(Option<String>),
    /// `/effort`, `/effort default`, or `/effort <level>`.
    Effort(Option<Choice>),
    /// `/proactive`, or on, off, default.
    Proactive(Option<bool>),
    /// `/persona`, alone or with one.
    Persona(Persona),
    /// `/clear --all`; a bare `/clear` is answered with how.
    Clear {
        /// Whether `--all` was said.
        all: bool,
    },
    /// `/unclear`: takes `/clear --all` back.
    Unclear,
    /// The limits the conversation sets for itself.
    Config(Config),
    /// `/bind`, `/bind <legacy group>` in a private chat, `/bind <code>` in
    /// a group.
    Bind(Option<String>),
    /// `/link`, where Max is to ask, or `/link <code>`, where it is to be
    /// asked.
    Link(Option<String>),
    /// `/unlink c#N`.
    Unlink(Option<String>),
}

/// A command's answer as it is said: the result, any more lines under
/// it, in a text code block, set apart from what Max says in a turn. It
/// doesn't name the command, which is the message right above it.
#[must_use]
pub fn answer(body: &str) -> String {
    fenced("text", body)
}

/// `body` in a code block of `language`. The fence outgrows any run of
/// backticks inside, as a persona may have.
pub fn fenced(language: &str, body: &str) -> String {
    let longest = body.split(|c| c != '`').map(str::len).max().unwrap_or(0);
    let fence = "`".repeat(longest.max(2) + 1);
    format!("{fence}{language}\n{body}\n{fence}")
}

/// What `/persona` is given.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Persona {
    /// Nothing: it shows the persona.
    Show,
    /// `clear`, `reset` or `default`: back to the default one.
    Reset,
    /// Anything else: the new persona.
    Set(String),
}

/// What a command sets something to: `default`, or what it says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Choice {
    /// The word `default`.
    Default,
    /// Any other word, as it was written.
    To(String),
}

impl From<&str> for Choice {
    fn from(word: &str) -> Self {
        match word {
            "default" => Self::Default,
            _ => Self::To(word.to_owned()),
        }
    }
}

/// `/config`, `/config <name>`, or `/config <name> <value|default>`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Config {
    /// Every limit as it is.
    All,
    /// The one of this name.
    One(String),
    /// The limit of this name is set.
    Set {
        /// The limit's name.
        name: String,
        /// What it is set to.
        value: Choice,
    },
}

/// The command a message gives Max, if any: in a group, only one that
/// @-mentions Max.
#[must_use]
pub fn given(inbound: &Inbound) -> Option<Command> {
    if inbound.chat.kind == ConversationKind::Group && !inbound.mentions_me() {
        return None;
    }
    inbound.plain_text().parse().ok()
}

/// The same, from what was read of the message already: whether it
/// @-mentions Max, and its plain text.
#[must_use]
pub fn in_text(kind: ConversationKind, mentions_me: bool, text: &str) -> Option<Command> {
    if kind == ConversationKind::Group && !mentions_me {
        return None;
    }
    text.parse().ok()
}

/// How to give `command` in a conversation of `kind`: after an @ of Max,
/// whose name there is `me`, in a group.
#[must_use]
pub fn how(kind: ConversationKind, me: &str, command: &str) -> String {
    match kind {
        ConversationKind::Group => format!("@{me} {command}"),
        ConversationKind::Direct => command.to_owned(),
    }
}

/// Anything else, such as `/nix/store`, `!help` or an unknown word: that
/// is chatter, not a command.
#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
#[error("not a command")]
pub struct NotACommand;

impl FromStr for Command {
    type Err = NotACommand;

    fn from_str(text: &str) -> Result<Self, NotACommand> {
        let rest = text.trim().strip_prefix(['/', '／']).ok_or(NotACommand)?;
        let (word, argument) = match rest.split_once(char::is_whitespace) {
            Some((word, argument)) => (word, argument.trim()),
            None => (rest, ""),
        };
        let argument = (!argument.is_empty()).then(|| argument.to_owned());
        Ok(match word.to_lowercase().as_str() {
            "status" => Self::Status,
            "kill" => Self::Kill,
            "stop" => Self::Stop,
            "start" => Self::Start,
            "model" => Self::Model(argument.filter(|argument| argument != "list")),
            "effort" => Self::Effort(argument.as_deref().map(Choice::from)),
            "proactive" => Self::Proactive(match argument.as_deref() {
                None => None,
                Some("on" | "default") => Some(true),
                Some("off") => Some(false),
                Some(_) => return Err(NotACommand),
            }),
            "persona" => Self::Persona(match argument {
                None => Persona::Show,
                Some(text) if ["clear", "reset", "default"].contains(&text.as_str()) => {
                    Persona::Reset
                }
                Some(text) => Persona::Set(text),
            }),
            "clear" => Self::Clear {
                all: argument.as_deref() == Some("--all"),
            },
            "unclear" => Self::Unclear,
            "config" => Self::Config(match argument.as_deref() {
                None => Config::All,
                Some(argument) => match argument.split_once(char::is_whitespace) {
                    None => Config::One(argument.to_owned()),
                    Some((name, value)) => Config::Set {
                        name: name.to_owned(),
                        value: value.trim().into(),
                    },
                },
            }),
            "bind" => Self::Bind(argument),
            "link" => Self::Link(argument),
            "unlink" => Self::Unlink(argument),
            _ => return Err(NotACommand),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Option<Command> {
        text.parse().ok()
    }

    #[test]
    fn commands_and_not() {
        assert_eq!(parse(" ／Status "), Some(Command::Status));
        assert_eq!(parse("/stop"), Some(Command::Stop));
        assert_eq!(parse("/START"), Some(Command::Start));
        assert_eq!(
            parse("/model test/big"),
            Some(Command::Model(Some("test/big".into())))
        );
        assert_eq!(parse("/model list"), Some(Command::Model(None)));
        assert_eq!(parse("/effort"), Some(Command::Effort(None)));
        assert_eq!(
            parse("/effort default"),
            Some(Command::Effort(Some(Choice::Default)))
        );
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
        assert_eq!(
            parse("/persona default"),
            Some(Command::Persona(Persona::Reset))
        );
        assert_eq!(parse("/clear"), Some(Command::Clear { all: false }));
        assert_eq!(parse("/clear --all"), Some(Command::Clear { all: true }));
        assert_eq!(parse("/unclear"), Some(Command::Unclear));
        let config = |config| Some(Command::Config(config));
        let set = |name: &str, value: Choice| {
            config(Config::Set {
                name: name.to_owned(),
                value,
            })
        };
        assert_eq!(parse("/config"), config(Config::All));
        assert_eq!(
            parse("/config call_time_secs"),
            config(Config::One("call_time_secs".into()))
        );
        assert_eq!(
            parse("/config  idle_window_secs   1800 "),
            set("idle_window_secs", Choice::To("1800".into()))
        );
        assert_eq!(
            parse("/config call_time_secs 90 or so"),
            set("call_time_secs", Choice::To("90 or so".into()))
        );
        assert_eq!(
            parse("/config call_time_secs default"),
            set("call_time_secs", Choice::Default)
        );
        assert_eq!(
            parse("/bind 123456"),
            Some(Command::Bind(Some("123456".into())))
        );
        assert_eq!(parse("/link"), Some(Command::Link(None)));
        assert_eq!(
            parse("/link 123456"),
            Some(Command::Link(Some("123456".into())))
        );
        assert_eq!(
            parse("/unlink c#7"),
            Some(Command::Unlink(Some("c#7".into())))
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
            "/stopwatch",
            "/linked",
            "",
        ] {
            assert_eq!(parse(chatter), None, "{chatter:?}");
        }
    }
}
