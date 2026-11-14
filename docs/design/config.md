# Configuration

## Configuration

Decided 2026-10-27. The Haskell version's configuration was merged field by field from three layers: the CLI, environment variables and YAML. Environment variables silently overrode the file, and unknown keys were silently ignored. The production configuration was assembled from three places: a complete configuration rendered from a sops template, an env file rendered from another sops template, and environment variables exported by the module. All of this is dropped.

### Source and validation

- **There is a single source: the TOML file.** The CLI has only subcommands and `--config`. No `MAX_*` environment variables are read, and the log level is also set in the file. There are no precedence rules.
- **Parsing is strict.** Every struct carries `deny_unknown_fields`. Default values are written in one place only, in the code. Optional features are `Option<Section>`: leaving a section out disables the feature. Cross-field validation runs at startup; for example, a referenced model must exist.
- **Secrets and private values are given only as file paths.** Keys use `api_key_file` and `access_token_file`. The same applies to identifiers that must not enter the public repository, such as the room allowlist, the group numbers used for mirroring and the owners: these use fields like `rooms_file`, with one entry per line. The configuration file itself contains nothing sensitive. All secret files are read at startup; if one is missing, the program reports an error and exits.
- **There is no hot reloading.** Any change requires a restart.

### Relationship to NixOS

- The module uses a freeform `settings`, which is generated into the Nix store through `pkgs.formats.toml`. Paths that the module manages itself (the database socket, the media directory) are written into `settings` with `mkDefault`; no environment variables are exported, and there is no `environmentFile`.
- At build time, `max check-config` validates the structure without reading the secret files. A mistake in the configuration therefore makes `nixos-rebuild build` fail.
- When the configuration changes, its store path changes and systemd restarts the service automatically; rotating a secret triggers a restart through sops-nix's `restartUnits`.
- In tank's `max.nix`, the owners are currently in plain text; they move into sops as part of the migration.

### Two layers: the configuration file and runtime settings

The configuration file holds the deployment-time infrastructure and defaults. Per-conversation overrides such as `/model`, `/effort`, `/persona`, `/proactive` and `/config` are stored in the database. The two are not merged into a single "configuration", and the code uses different types for them.

### Settings a conversation sets

Added 2026-11-08, proposed by the owner: some limits are no longer fixed in code. A conversation sets them for itself, through the command `/config` or through Max's tool `config` (`max.config`), so that Max can configure itself.

- **Which**: `idle_window_secs`, how long a core waits idle before it ends, 60–7200 (see [Processing flow](actor.md#processing-flow)); `call_time_secs`, the wall clock of each call a program or a command makes to a Max tool of the host's, `tools.file` included, 10–600. They are `max_core::limits::Setting`. A third, `commands_at_once`, went on 2026-11-12 with the count it set: a background command is a unit of the guest's now (see [Background commands](jobs.md#background-commands)). The names are the same in the configuration file, the command, the tool and `/status`, and each range is written once, in `Setting::range`, which the file's validation, the command's parser and the tool's schema all use.
- **Precedence**: the conversation's value, else the configuration file's, else the default in `limits.rs`. The file's are in an optional `[limits]` section (`call_time_secs`); the idle window stays each provider's `idle_window_secs`, since it follows that provider's cache. A conversation holds one value per setting, whoever set it: the last to set it wins, a person's `/config` and Max's `config` alike (decided by the owner 2026-11-08; the alternative, in which a person's setting locks it against Max, was rejected).
- **Stored** in `conversation_settings.overrides` (migration 0026), JSON with a key for each setting that has been set. A value that can't be read counts as nothing set, rather than stopping the conversation.
- **When a change takes effect**: the idle window at once, for the running turn too (the actor computes the deadline from it on every pass); the call time from the next call of a Max tool, which takes it as it starts (until 2026-11-12 a `run_code` or `shell` kept what its session took when it opened).
- **`/config`** lists every setting, with the default after those that have been set; `/config <name>` shows one; `/config <name> <number>` sets it, and `/config <name> default` clears it. Anyone can look; setting needs the group owner, an administrator or an owner (in a private chat, the other party), as it changes only this conversation and costs no money. A reply reads `call_time_secs set to 120; takes effect from Max's next program or command`.
- **`config({ idle_window_secs?, call_time_secs? })`**: with no arguments it only shows; a field given sets it, and 0 returns it to the default (null means "not given", as everywhere in the tools). It returns each setting's `{ value, default }`. Whether to change one is left to Max's judgement, as with `mute_member`: when someone asks with a sensible reason, or when it needs to, saying so briefly afterwards. A background agent can't call it. The change goes through the conversation actor (`Request::Configure`), the settings' only writer, which saves it; it is refused when the turn that asked has ended.
- **What isn't configurable yet**: the limits the model is told of, in the system prompt, in `run_code`'s and `shell`'s descriptions or in a tool's guide (`RUN_TIME`, `BACKGROUND_TIME`, `SHOWN_BYTES`, `PICTURES_PER_RUN`, `VIDEO_SECONDS`, `KEPT_FILE_BYTES`, `SENT_FILE_BYTES`, `MEMORY_TOKENS`, `JOBS_AT_ONCE`, `JOB_TIME`, `QUESTION_WAIT`, `ASK_WAIT`, …). The prompt and the tools are the same for every conversation, so that they stay cached; these need them rendered per conversation, and a change would show only from the next turn. That is the next step, with those that cost money (`JOBS_AT_ONCE`, `JOB_TIME`, `MEMORY_TOKENS`) for owners only, like `/model`. Those that keep the plumbing honest (`CALLS_AT_ONCE`, the byte caps, `MEMORY_FILE_BYTES`) and the classifier's guard `JUDGED_WAKES_PER_HOUR` stay fixed.

### LLM: providers, models and selection

As in Codex, pi and Hermes, this is split into three layers. The Haskell version folded the three layers into one: of the 23 profiles on tank, only 7 had distinct addresses, and two pairs were the same model differing only in reasoning effort.

1. **Provider: how to connect.** The address, the protocol (`responses` or `chat`), authentication, request headers, retries, timeouts, NInfer's cache breakpoints `cache_breakpoints`, and the idle window `idle_window_secs` (default 300; see [Processing flow](actor.md#processing-flow)). If the same address is needed for both chat and responses, it is written as two providers. The idle window is set according to the lifetime of that provider's cache (checked 2026-10-27): from OpenAI GPT-5.6 onwards, the default is at least 30 minutes, renewed on every read; Anthropic defaults to 5 minutes, with 1 hour as an option; Gemini publishes no official figure, and third parties estimate 3–5 minutes (tested live on 2026-10-31: after a few minutes, only the part before the last message of the previous request is reused, and that part was still cached after 6 minutes; see [Rules for a stable prefix](context.md#rules-for-a-stable-prefix)); DeepSeek keeps it from several hours to several days; local vLLM and SGLang are limited only by GPU memory.
2. **Model: what it is.** A model sits under a provider, and its TOML table name is the model id sent to the API. It records the context window, the maximum output, the input modalities, whether reasoning is supported, and the default sampling parameters.
3. **Selection: who uses which model, and how.** The default model, and the model and reasoning effort used by each role (for example, intent). References are always written as `provider/model` and split at the first `/`; provider names may not contain `/`.

```toml
[database]
url = "postgresql:///max?host=/run/postgresql&user=max"

[platforms.qq]
app_id_file = "/run/secrets/max/qq-app-id"
app_secret_file = "/run/secrets/max/qq-app-secret"

# Optional: the defaults of what a conversation may set with /config
[limits]
call_time_secs = 60

# Layer 3: who uses which model, and how
[llm]
default = { model = "cliproxy/gpt-5.6-luna", effort = "xhigh" }
intent = { model = "local/qwen3.5-4b" }

# Layer 1: how to connect
[llm.providers.cliproxy]
base_url = "https://cliproxy.example/v1"
protocol = "responses"
api_key_file = "/run/secrets/max/cliproxy-api-key"
retries = 2
stream_idle_timeout_secs = 120
idle_window_secs = 300

# Layer 2: what it is (the values are only examples)
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

- Streaming requests use an idle timeout rather than a total duration, and the retry count is set on the provider. The Haskell version allowed up to 1800 seconds per attempt; when the network was poor in the evenings, retries stacked on top of that and the delays compounded.
- There is no built-in model catalogue. At startup, the configuration is checked once against the server's `/models`.
- `price` is the model's list price from its maker, in US dollars per million tokens: `input`, `cached` (input read from the cache; the input's price if left out) and `output`, reasoning included. It is the public API price even when the model is reached through a subscription or is free to us (decided by the owner on 2026-11-12), so that the cost `/status` shows compares models; a model without one is left out of that cost, which then reads `≥ $…`. Tiers for long prompts are ignored: the shortest prompts' price is used.
- `video = true` on a model means that it can watch video (Gemini's models do); `tools.video` is available only on such models; see [Multimodal results](tools.md#multimodal-results).
- `/model` only selects a `provider/model`, and `/effort` only adjusts the effort. There are no longer profiles such as `gpt-5.6-luna-medium` that differ only in effort.
- The models and efforts that old conversations had selected are not imported (decided by the owner on 2026-10-29; the original plan was to map profile names to "model plus effort"). maxx's configuration does not contain those models, and once a conversation has selected an unknown model, every turn in that conversation fails. All conversations use the default and can switch with `/model` when needed. `llm_usage` is not imported.

v1 defines only the sections it uses: database, `platforms.qq` and llm, plus the top-level `owners_file`, `utc_offset` and `log`. Intent has no configuration options (the `[intent]` section was removed on 2026-10-29); see [Intent](intent.md#intent-1). Other sections are added together with their features.
