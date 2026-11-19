# Configuration

There are two layers, kept apart in the code by different types: the
configuration file holds deployment infrastructure and defaults
(`crates/max/src/config.rs`), and the database holds what each
conversation set for itself (`/model`, `/effort`, `/persona`,
`/proactive`, `/config`). They are never merged into one "configuration".

The Haskell version merged its configuration field by field from the CLI,
environment variables and YAML: environment variables silently overrode
the file, unknown keys were silently ignored, and production's came from
three places. None of that is kept.

## Source and validation

- **One source: the TOML file.** The CLI has only subcommands and
  `--config`. No `MAX_*` environment variables are read; the log level is
  in the file too. There are no precedence rules.
- **Strict parsing.** Every struct has `deny_unknown_fields`. Defaults are
  written once, in the code. An optional feature is an `Option<Section>`:
  leave the section out and the feature is off. A value with a form of
  its own is read as its type, so one that isn't of that form is the
  parser's error, with its place in the file: a `provider/model`, a base
  URL, a slot's address with its prefix, a gateway or a resolver. Cross-
  field checks run at startup (a referenced model must exist, say).
- **Secrets and private values are file paths.** Keys are
  `api_key_file`, `secret_file` and the like; identifiers that mustn't
  reach the public repository, such as the owners, are files too
  (`owners_file`, one per line). The configuration file holds nothing
  sensitive. Every secret file is read at startup, and a missing one stops
  max with an error.
- **No hot reload**: a change means a restart.

The top-level sections: `utc_offset`, `owners_file`, `log`, `database`,
`llm`, `platforms.qq`, `limits`, and the optional `vm`, `media`, `search`,
`embedding`, `github` and `api`, each described with its feature.

## NixOS

- The module (`nix/module.nix`) takes a freeform `settings`, generated into
  the store with `pkgs.formats.toml`. Paths the module manages (the
  database socket, the media directory) are set in `settings` with
  `mkDefault`; no environment variables, no `environmentFile`.
- At build time `max check-config` validates the structure without reading
  the secret files, so a mistake fails `nixos-rebuild build`.
- A changed configuration has a new store path, and systemd restarts the
  service; rotating a secret restarts it through sops-nix's
  `restartUnits`.

## Settings a conversation sets

Some limits are set by each conversation, with the command `/config` or
Max's tool `config`, so that Max can configure itself.

- **Which**: `idle_window_secs`, how long a core waits idle before it ends,
  60 to 7200 (see the [Processing flow](actor.md#processing-flow)); and
  `call_time_secs`, the wall clock of each call a program or command makes
  to one of Max's tools, `tools.file` included, 10 to 600. They are
  `max_core::limits::Setting`. Each name is the same in the configuration
  file, the command, the tool and `/status`, and each range is written
  once, in `Setting::range`, which the file's validation, the command's
  parser and the tool's schema all use.
- **Precedence**: the conversation's value, else the configuration file's,
  else the default in `limits.rs`. The file's are in `[limits]`
  (`call_time_secs`); the idle window is each provider's
  `idle_window_secs`, since it follows that provider's cache. A
  conversation holds one value per setting, whoever set it: the last to set
  it wins, a person's `/config` and Max's `config` alike.
- **Stored** in `conversation_settings.overrides`, JSON with a key per
  setting set. A value that can't be read counts as unset, rather than
  stopping the conversation.
- **When a change takes effect**: the idle window at once, for the running
  turn too (the actor works out its deadline on every pass); the call time
  from the next call of one of Max's tools, which takes it as it starts.
- **`/config`** lists every setting, with the default after those that are
  set; `/config <name>` shows one; `/config <name> <number>` sets it and
  `/config <name> default` clears it. Anyone can look; setting needs the
  group owner, an administrator or an owner (in a private chat, the other
  party), as it changes only this conversation and costs no money. A reply
  reads `call_time_secs set to 120; takes effect from Max's next program or command`.
- **`config({ idle_window_secs?, call_time_secs? })`**: with no arguments
  it only shows; a field given sets it, and 0 returns it to the default
  (null means "not given", as everywhere in the tools). It returns each
  setting's `{ value, default }`. Whether to change one is Max's judgement,
  as with `mute_member`: when someone asks with a sensible reason, or when
  it needs to, saying so briefly afterwards. The change goes through the
  actor (`Request::Configure`), the settings' only writer.

## Models

As in Codex, pi and Hermes, three layers:

1. **Provider: how to connect.** The address, the protocol (`responses` or
   `chat`), authentication, headers, retries, timeouts, NInfer's cache
   breakpoints `cache_breakpoints`, and the idle window `idle_window_secs`
   (300 by default). One address serving both protocols is two providers.
   The idle window follows the provider's cache lifetime: OpenAI's (from
   GPT-5.6) is at least 30 minutes, renewed on every read; Anthropic's 5
   minutes, or an hour as an option; Gemini publishes none, and keeps only
   whole messages after a few minutes (see
   [decisions/tail-split-by-turn.md](../decisions/tail-split-by-turn.md));
   DeepSeek's lasts hours to days; local vLLM and SGLang are limited only
   by GPU memory.
2. **Model: what it is.** A model sits under its provider, and its table
   name is the model id sent to the API. It records the context window,
   the maximum output, the input modalities, whether it reasons, default
   sampling and its price.
3. **Selection: who uses which model, and how.** The default, and the
   model and effort of each role: `intent`, and the optional `caption`
   and `job` (the background agents' default). References are
   `provider/model`, split at the first `/`; provider names may not
   contain `/`.

```toml
[database]
url = "postgresql:///max?host=/run/postgresql&user=max"

[platforms.qq]
app_id_file = "/run/secrets/max/qq-app-id"
app_secret_file = "/run/secrets/max/qq-app-secret"

# Optional: the defaults of what a conversation may set with /config
[limits]
call_time_secs = 60

# Selection: who uses which model, and how
[llm]
default = { model = "cliproxy/gpt-5.6-luna", effort = "xhigh" }
intent = { model = "local/qwen3.5-4b" }

# Provider: how to connect
[llm.providers.cliproxy]
base_url = "https://cliproxy.example/v1"
protocol = "responses"
api_key_file = "/run/secrets/max/cliproxy-api-key"
retries = 2
stream_idle_timeout_secs = 120
idle_window_secs = 300

# Model: what it is (the values are only examples)
[llm.providers.cliproxy.models."gpt-5.6-luna"]
context_window = 400000
max_output = 128000
reasoning = true
price = { input = 1.25, cached = 0.125, output = 10 }   # US$ per million tokens

[llm.providers.local]
base_url = "http://127.0.0.1:8080/v1"
protocol = "chat"

[llm.providers.local.models."qwen3.5-4b"]
context_window = 32768
```

- A streaming request has an idle timeout rather than a total duration, and
  retries are the provider's. (The Haskell version allowed 1800 seconds an
  attempt, and on bad evenings the retries compounded.)
- There is no built-in model catalogue; at startup the configuration is
  checked once against the server's `/models`.
- `price` is the maker's list price in US dollars per million tokens:
  `input`, `cached` (input read from the cache; `input` if left out) and
  `output`, reasoning included. It is the public API price even for a
  model reached through a subscription or free to us, so that the cost
  `/status` shows compares models; a model without one is left out of that
  cost, which then reads `≥ $…`. Tiers for long prompts are ignored.
- `video = true` marks a model that can watch video; `tools.video` exists
  only on such models (see [Multimodal results](tools.md#multimodal-results)).
- `/model` picks a `provider/model`, or with `default` drops the
  conversation's choice, so that it follows `llm.default` again; `/effort`
  picks only the effort; there are no profiles that differ only in
  effort. (The Haskell version folded the three layers into one: of
  tank's 23 profiles, 7 had distinct addresses.)
- Intent has no options; its constants are in `max-core` (see
  [Intent](intent.md)).

## Open

What the model is told of isn't configurable per conversation yet: the
limits in the system prompt, in `run_code`'s and `shell`'s descriptions or
in a tool's guide (`RUN_TIME`, `BACKGROUND_TIME`, `SHOWN_BYTES`,
`PICTURES_PER_RUN`, `VIDEO_SECONDS`, `KEPT_FILE_BYTES`, `SENT_FILE_BYTES`,
`MEMORY_TOKENS`, …). The prompt and the tools are the same for every
conversation, so that they stay cached; these would need them rendered per
conversation, and a change would show only from the next turn. Those that
cost money (`MEMORY_TOKENS`, say) would be for owners only, like `/model`.
Those that keep the plumbing honest (`CALLS_AT_ONCE`, the byte caps,
`MEMORY_FILE_BYTES`) and the classifier's guard `JUDGED_WAKES_PER_HOUR`
stay fixed.
