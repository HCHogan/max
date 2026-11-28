# Tools and codemode

The model has two tools, `run_code` and `shell`, which run in the group's
VM; everything else Max can do is a tool that programs and commands there
call. The host's tools are in `crates/max/src/service`, the guest's side in
`nix/` (`runner.js`, `client.js`, `tools.js`, `maxx.js`, `maxx.nix`,
`local.json`).

## Pure codemode

- **Only `run_code` and `shell`.** The tools array never changes, so it
  never invalidates the request's prefix; what matters is that the set is
  fixed, not that it is small. A round may hold several calls, each run
  independently.
- **`run_code({code, args?, timeout_ms?})`**: `code` is the body of an async
  function, and what it `return`s is the result.
- **`shell({command, workdir?, timeout_ms?, background?})`**, close to
  Codex's shell tool: `bash -lc` in the group's VM, in `/work` by default.
  The result is the exit status and the combined output. It exists beside
  `run_code` because commands through JS are worse in every way: each needs
  `child_process` code, a non-zero exit throws and loses stderr, the command
  sits in a JS string inside JSON with an extra layer of escaping, and
  `${VAR}` in a template string is JS's first. Models are trained most on
  shell tools. It adds nothing in security: `run_code` could already
  `execSync`, and everything in the VM runs as root. With `background`, the
  command runs on after the call as a background command (see
  [Background commands](jobs.md#background-commands)).
- **Max's tools from a program**: `tools.<name>(args)` returns a Promise, so
  `Promise.all` gives concurrency. `tools.x()` throws `ToolError` on
  failure; `max.raw` doesn't, and returns `{ok: true, value}` or
  `{ok: false, error: {code, message}}`; `max.cancel` aborts a request, and
  `max.race` takes whichever call ends first and cancels the rest. Reading a
  field of a call not awaited fails at once, with a hint to await it. `max`
  also has the browser's `page`, `browser` and `snapshot`.
- **Max's tools from a command**: `maxx` (below), so `shell` and programs in
  any language call the same tools.
- **Declarations**: the system prompt holds the TypeScript declarations of
  Max's tools, return types included, generated from the tools themselves
  (see [Tool contract](#tool-contract)). A model sometimes calls one as a
  tool of its own, `web_search` mostly: the call's result says there are
  only the two, and how the one it named is called from a program.
- **No skills yet.** If they come, a skill is only documentation: loading
  one appends its manual to the context, and the tools array doesn't change,
  so the core needs no active tool set, and neither Responses'
  `tool_search` nor meta-tools are needed.
- **Call format**: a function tool with JSON arguments. Whether code arrives
  as raw text or escaped in a JSON string depends on the model: Claude's
  string parameters and Qwen 3.5/3.6's XML parameters carry raw text; GPT and
  Gemini escape it, and Gemini sometimes adds a layer (gemini-cli has code to
  undo it). aider measured in 2024 that wrapping code in JSON lowered every
  model's pass rate. Not addressed yet; see [Open](#open).
- **Cost**: every tool depends on the VM. If it can't start, the model can
  still answer in text, and `/status` shows the VM's state.

## maxx: one command for everything in the VM

`maxx` is the guest's command for every tool: the host's (by HTTP) and the
guest's own. A program has them all as `tools.<name>`. Beside the tools is
`maxx jobs`, which is max's own: what the host runs for a call and for a
background command.

- **One source per tool.** A host tool is written once, on the host
  (`service::tool::TOOLS`); a guest tool is declared once, in
  `nix/local.json`: its name, the words of its command line, what runs it
  (the guest's script, or Node), whether the prompt declares it (`turn`), a
  line for `maxx`'s list, its guide and both schemas. `maxx` reads the
  host's options from `GET /tools` and the guest's from `local.json`, the
  runner makes `tools.<name>` from both, and the host reads `local.json` as
  it is built for the prompt's declarations (`service::tool::LOCAL`).
- **One client**: `nix/client.js`, shared by the runner, `maxx.js` and
  `tools.js`. (The SDK doesn't wrap `maxx`: every `tools.x` would start a
  process, twenty in a `Promise.all`, with errors and pictures relayed
  through exit codes. The cost the other way is that each `maxx` starts Node,
  a few tens of milliseconds, so a loop of a hundred calls belongs in
  `run_code`.)
- **The guest's tools**: `show` and `video`, which leave the model
  something to see; `events`, the chat's rows as they come; and `units
  apply`, which makes the units Max keeps the ones that run (see
  [Resident programs](jobs.md#resident-programs)). A guest tool goes by its
  words (`maxx units apply`), and in a program by its name
  (`tools.units_apply`).
- **Declared in the prompt**: `show`, `video` and `units_apply`, with the
  host's tools. `events` is a program's, and can be called without being
  declared, as `say` and `wake` can.
- **What systemd does needs no tool.** What runs in the VM Max sees and
  stops with `systemctl`: `systemctl list-units 'max-job-*'` lists its
  background commands, each with its title for a description, and
  `systemctl stop <unit>` stops one. Nothing of `maxx` wraps them.
- **How one runs**: `bin/maxx` is a shell script (`nix/maxx.nix`). `units
  apply`, given its words alone or with one JSON object, is its script
  (`max-units.sh`), and Node never starts. Anything else goes to Node
  (`maxx.js`), which reads the options against the schema; for `units
  apply` it calls `maxx` back with the JSON, and a program's
  `tools.units_apply` does the same (`tools.js`), so the tool runs one way
  whoever calls. The script answers with one JSON object on stdout, a
  failure with its reason on stderr and status 1, a wrong command line with
  status 2, which a program sees as `failed` and `bad_arguments`.
- **`maxx jobs` is max's own, and no tool**: `maxx jobs run '{…}'` for
  every `shell` and `run_code`, `maxx jobs start '{…}'` for a background
  command, and the hooks of their units, `ended`, `notify` and `idle`
  (`nix/max-jobs.sh`; see [Background commands](jobs.md#background-commands)).
  `bin/maxx` hands them to the script as they are. Each takes one JSON
  object and nothing else: they aren't listed, and have no schema, options
  or defaults, since the one that asks is max, of the image's own build.
- **The command line**: `maxx tool --param value` or `--param=value`; a bare
  `--param` is true and `--no-param` false; or one JSON object, `-` reading
  it from stdin. Words without a name fill the required parameters in order,
  then the rest. Arguments are converted to the schema's types; repeating an
  array parameter gives several items. A value of `-` for a text argument is
  stdin: `maxx say --text - <<'EOF'`. `maxx` alone lists the tools, and
  `maxx tool --help` gives the tool's guide (the prompt's) and its result's
  shape, which is all a background agent is told of. On success JSON goes to stdout; a
  failed tool writes `tool: reason (code)` to stderr and exits 1; a malformed
  command line exits 2.
- **Arguments are read strictly**:
  - A word beginning with a brace is the arguments only when it is a JSON
    object, or begins as a program writes one, `{"`; any other is text, so
    `maxx say '{笑}'` works.
  - After `--` every word is positional, and `-h` asks for help only in the
    first place.
  - A name written another way (`units-apply`, `units_apply`) is told how it
    is written; only the words run it.
  - `maxx events` reads its arguments as any call does.
  - A host tool given one JSON object is called at once, without asking for
    the list first. One request to the host costs about 95 ms and Node's
    start 65 ms.
- **Answers are JSON**: `units apply` says each unit's state, the files it
  skipped and why, and what it removed.
- **`tools.events({after})`** is what `maxx events` prints, for JS: an async
  iterator of the rows (see [Resident programs](jobs.md#resident-programs)).
  A program of Max's own, not run_code's, has the same `tools` with
  `require("/run/max/tools.js")`.
- **Tests**: `nix/tests/jobs.nix` asks for `units apply` as Max does, by its
  words, and has a program call `tools.units_apply`.

## Running in the group's VM

Programs run on Node in the group's VM rather than in a JS engine inside
max (the Haskell version used QuickJS in wasmtime): `/work` is shared with
the background agents, so handing over work is leaving files; the browser
is driven with Playwright directly; and Max maintains no engine, stepping
protocol or ABI.

- **A new process each run**: the host runs `maxx jobs run` in the VM over
  SSH, which starts the call as a transient unit of the guest's. For
  `run_code` the unit runs `node /run/max/runner.js`, read-only in the guest
  image; stdin carries the program and its arguments; the result and the
  console come back as files of the unit. Exit 0 is a normal return, 1 an
  exception, reported as its whole message and the program's own line
  numbers: Playwright says why in the lines after the first, what a click
  waited for and what was in its way, which elements a selector matched.
  A program has Node's `require`, resolving as a file in `/work` would.
  Each run goes through `bash -lc`, so a program's children have a login
  environment. Nothing is resident, so runs share no state.
- **Startup**: the VM starts on demand and runs commands after about 4.5
  seconds, and stops after two idle hours. It starts as soon as a `run_code`
  or `shell` call appears in the model's stream, overlapping with the time
  the model spends writing the code; turns with no tools don't start it.
- **Limits**: the VM's CPU, memory and network policy, and each call's wall
  clock, kept by the guest's systemd (`RuntimeMaxSec=`); a call dropped
  before its unit ends, as when its turn is killed, has its channel closed,
  and the guest stops the unit. No determinism, no fuel.
- **To the core**, `run_code` and `shell` are each one tool call; the tools a
  program calls are no inputs to it.
- **One log line per call**, `a tool call ends`: the conversation, the tool
  (`run_code`, `shell` or `background`), whether the program used the
  browser (its code contains `max.page(`, `max.browser(` or
  `max.snapshot(`), how long it took, whether it failed and the result's
  tokens. Not the code or the output: browser programs often hold accounts
  and passwords typed in for someone. (The database alone couldn't show
  which of a model's 126 clicks through a cloud console were wasted.)
- **The known risk**: everything in the VM runs as root, and anything there
  may call every tool, in a turn or outside one, so a process an earlier
  prompt injection left behind can speak in the chat, mute and recall as
  Max's programs can. Accepted: a VM is its own group's, and what the tools
  can do there is what Max can.
- **Testing**: the runner depends only on stdio and HTTP, so a test runs
  it with Node locally against max's service on a TCP port, with no VM: a
  program that calls Max's tools and returns.

## The guest's calls

Processes in the VM call the host's tools over plain HTTP, through the
guest's one client: `run_code`'s runner, `maxx`, and programs of Max's own
that require the tools. The guest's own tools ask the host nothing. Why the
channel is plain HTTP, and every caller in a VM one caller, is in
[decisions/guests-reach-max-directly.md](../decisions/guests-reach-max-directly.md).

- **The channel**: with cloud-hypervisor's hybrid vsock, a guest connecting
  to a port on the host lands on the UNIX socket `<vsock socket>_<port>`.
  A VM's `notify.vsock_7777` is a link to the one socket max listens at
  (see [A guest's calls reach max](vm.md#a-guests-calls-reach-max)); which
  VM is calling is the process's to say that made the connection, the VM's
  own cloud-hypervisor. In the guest,
  `127.0.0.1:7777` is forwarded to that port by the socket-activated
  `max-host` (one socat per connection to vsock 2:7777), and every client is
  given `http://127.0.0.1:7777` (`MAXX_URL`). The host stays unreachable at
  the IP layer, and the VM from outside.
- **The protocol**: `GET /tools` lists the host's tools with their schemas
  and guides; `POST /tools/<name>`, its body the arguments as a JSON object,
  calls one. The answer is the call's outcome, `{"ok": true, "value": …}` or
  `{"ok": false, "error": {"code", "message"}}`, both with status 200;
  arguments that aren't a JSON object get 400 in the same shape. A call made
  while max restarts waits on the host and is answered by the max that comes
  (see [A VM outlives max](vm.md#a-vm-outlives-max)); the guest's client
  asks once. Closing the connection cancels the call,
  and `max.cancel` simply aborts the fetch.
- **One caller**: a call is the VM's. It goes to the conversation's actor
  (`Signal::Call`, `Conversation::program_call`), which runs it in `side`
  within the conversation's `call_time_secs`, with a `Poster` that names no
  turn; 64 at once for a VM (`CALLS_AT_ONCE`), the rest queued. When the
  caller closes its connection, the handler stops waiting and the actor drops
  the call. The host doesn't know what in the VM called: a turn's program, a
  background command, an agent or a unit of Max's. `service::Context` is the
  conversation, its services, its `/work` and a `Poster` (none for
  `vm-check`, which runs the calls itself).
- **One log line per call**, `a program's call ends`: the conversation,
  the tool, how long it took and how it ended: `ok`, the failure's code, or
  `dropped` when the caller left first. Not the arguments or the result. A
  turn's run holds its programs and commands, not the calls they made, and
  what agents and units call is written nowhere else: this is what says
  which of Max's tools they use, how often one fails and how long one
  takes.
- **No retries, no classes of side effect**: the host never retries; that is
  the model's decision. What affects the group (saying, sending, retracting)
  goes through the actor into the ledger, so whether it happened shows on the
  timeline. Timeouts and cancellations are reported as "may already have
  taken effect; check the records before trying again". The worst case, a
  call made again at once after a timeout sending one picture twice, is
  accepted.

### Tool contract

Each host tool is written once, in `max`, by implementing
`service::tool::Tool`: its name, a sentence for the list, its argument and
result types, its guide for the system prompt, and its function. Arguments
and results are serde types deriving schemars' `JsonSchema`; constraints are
attributes (`length`, `range`), field descriptions are `description`, and
numbers in descriptions and guides refer to constants. The registry
`service::tool::TOOLS` makes three things from them:

- The `inputSchema` and `outputSchema` that `GET /tools` lists: sub-schemas
  inlined, titles and integer formats removed, only the fields' own
  descriptions kept. A result with several shapes (`history`) is an `anyOf`
  with `type: object` at the root, so arguments and results are always
  objects.
- Checks before the call: string lengths (in characters) and numeric ranges
  against the schema, with messages such as
  `history 的 before 要在 0 到 50 之间`; types, required and unknown fields when
  serde reads the arguments. Out-of-range values are errors, never silently
  cut.
- The TypeScript in the system prompt: `/** guide */` and a signature from
  the two schemas, optional fields as `x?: T`, required nullable ones as
  `x: T | null`.

serde_json's `preserve_order` lists fields in declaration order. The
declarations' full text is an insta snapshot, so any change to a tool's
description shows in the snapshot's diff.

## Multimodal results

Programs hand pictures and videos to the model explicitly, as Codex's code
mode does with `image()`: only what is handed over enters the context, and
screenshots or downloads only make files. Codex's, pi's and Hermes's
approaches were consulted.

- **`tools.show({path})`**, or a picture's bytes in place of the arguments
  (`tools.show(await page.screenshot())`), and `maxx show path`. `path` is
  under `/work` (relative paths too); bytes are first written to
  `/work/.max/shown/<unit>/`, the call's own directory, cleared an hour later.
  It returns `{path}`; a path that isn't a file throws, and whether the
  picture decodes and fits, the host says in the result. Pictures from the
  chat are copied out with `tools.file` first.
- **How they reach the host**: nothing is asked of it. A call's unit has its
  directory in `MAX_CALL` (`/run/max/jobs/<unit>`), and `show` and `video`
  append a line to `shown` there (`nix/shown.js`). `maxx jobs run` gives the
  list back on the call's line, and the host reads the files as it builds the
  result (`tools/show.rs`): under `/work` one component at a time without
  following links, at most 10 MiB, made into the model's version as at
  download (see [Media](media.md#storing)), stored in the content store, and
  appended in order after the text as `Part::Media`, each estimated at 1,200
  tokens. One that can't be shown (not a picture, too big, one too many, a
  video for a model that doesn't watch them) is a line of the result,
  `<path> wasn't shown: <why>`, since the program is over by then. At most 16
  entries are looked at, and the line carries the first 32 (max keeps 256 KiB
  of a call's line). What isn't a call (a background command, an agent, a
  unit) has no `MAX_CALL`, and `show` fails with "nobody is there to see it".
- **A neutral format**: `ToolOutput { parts: Vec<Part>, error: bool }`, a
  `Part` being text, media or video, rendered like message media.
- **Budget**: one call shows at most 4 pictures (`PICTURES_PER_RUN`), the same
  picture (by hash) counting once. A request includes every picture in the
  turn's tool results: the next turn doesn't have them anyway, and leaving
  old ones out would change earlier results and miss the cache. The text
  `[这张图省略了，要看再 tools.show]` appears only when a picture can't be read
  from the content store.
- **Downgrading**: Responses writes a result with pictures as an array of
  `input_text` and `input_image`, one without as a string. Chat writes
  `[图 n，见下]` in the tool message, and after a run of tool messages one user
  message holds the pictures by number, which also suits providers that don't
  accept arrays in tool content.

### Video

The model watches a video whole, picture and sound, with no frames
extracted, on models that can (`video = true`; the Gemini models on tank).

- **Why it works**: cliproxy turns a Chat `video_url` data URL into Gemini's
  `inlineData`, and a Gemini model correctly described a 6-second test clip's
  colours, length, which part had sound and each part's pitch. Billing is by
  length, about 87 tokens a second (a frame a second plus audio); size costs
  time instead (a 54 MiB clip took 77 seconds to answer).
- **`tools.video({path, start, end})`** and `maxx video path --start --end`:
  `path` a file in the VM, `start` and `end` seconds or strings like
  `"1:30"`. It returns `{seconds}`, the piece's length by the guest's ffprobe.
  Videos from the chat are copied out with `tools.file`; Max downloads videos
  from the web itself.
- **Shrunk in the VM first** (`nix/video.js`): every later model call in the
  turn sends the video again, so ffmpeg makes an MP4 at one frame a second
  (what Gemini samples anyway), edges at most 640, mono 32k audio,
  `+faststart`: a two-minute clip becomes a few MB, in about a second. ffprobe
  checks the length first, and one over the limit isn't converted. The host
  never decodes video: chat videos are untrusted, and ffmpeg's parsers have
  frequent CVEs.
- **The host** reads the file as for `show`, at most 32 MiB (`VIDEO_BYTES`),
  reads only the MP4's `ftyp` and `moov/mvhd` for its length (rounded, at
  least 1 second; `media/mp4.rs`), refuses anything else, and stores it: a
  `Part::Video { media, seconds }`, estimated at 100 tokens a second. A model
  that doesn't watch video gets `这个模型看不了视频` (`unavailable`).
- **Budget**: one call's videos total at most 10 minutes (`VIDEO_SECONDS`),
  the same clip counting once; a request includes only the latest clips
  totalling 10 minutes, since a clip can be 32 MiB, and older ones read
  `[这段视频省略了，要看再 tools.video]`.
- **Downgrading**: in Chat, like pictures, as `[视频 n]` and a `video_url` in
  the following user message, with `[视频 n，见下]` in the tool message.
  Responses doesn't take video and writes `[这里有一段视频，这个模型看不了]`.
- **Tests**: `service/runner_tests.rs` makes a Matroska clip with the dev
  shell's ffmpeg and goes through the runner and `maxx`, checking the
  conversion, the length, the 10-minute limit and models that don't watch;
  `max-llm` checks both downgrades; vm-check makes a clip with the VM's ffmpeg
  and runs `maxx video`.

## Web search

- **`web_search({query, limit?})`** calls Exa's REST API on the host
  (`type: auto`, with highlights), the key staying there (`[search]
  api_key_file`, `search-exa-api-key` in sops; without it, `unavailable`). It returns the title, link,
  summary and date of the top results, `limit` 1 to 10, 5 by default, titles
  cut at 200 characters and summaries at 400: Exa's highlights mostly run
  longer, five results cut so come to about 4 KB, and a program that makes
  four searches at once still gets them whole in the 16 KiB `run_code`
  shows of a result, as the guide says. At most 4 searches run at once
  across all groups, within the call time. Exa goes out through the host's
  Japanese exit and its Chinese results are middling; Bocha or Zhipu,
  reachable within China, could stand behind the same signature.
- It stays among the prompt's declarations, not in a skill: hidden in a
  skill in the Haskell version, it went unused and the model answered prices
  and plots from memory (a51424d). Its guide says to search before answering
  what may be out of date, and that what the model knows ends with its
  training, often long before `[现在]`, so versions, releases, prices,
  schedules, office holders and recent events are searched even when it feels
  sure, going by the results dated nearest `[现在]`.
- **Fetching pages is no host tool**: the host reaches the tailnet, so one
  would open an SSRF hole. The guest has `webread <url>`: Python with
  trafilatura extracts the main text as Markdown (and handles legacy
  encodings such as GBK), PDFs go through `pdftotext`. It follows up to 5
  redirects, within 20 seconds and 10 MB, prints the first 12,000 characters
  (`WEBREAD_CHARS`, checked by a test against the Python) and writes the
  whole to `/work/.max/web/`, where `--offset` reads on. nft keeps the VM off internal
  networks. Pages needing JS or a login are the browser's.
- Not done: answer synthesis, the model APIs' built-in search (the tools
  array is fixed, and programs couldn't get those results), caching, image
  search.

## The browser

A Chromium resident in the group's VM, which programs drive with Playwright
over CDP, so a page the model looked at is still there for the next
`run_code` to click. Why Chromium and not camoufox is in
[decisions/resident-chromium.md](../decisions/resident-chromium.md).

- **The service**: `max-browser.service` runs nixpkgs' Chromium with
  `--headless=new`, CDP on 127.0.0.1:9222 only, as root with Chromium's own
  sandbox off (the VM is the sandbox). The profile is `/work/.max/chromium`,
  so cookies and logins survive VM restarts; locks left by an unclean
  shutdown are removed before it starts. Chinese UI and `Accept-Language`,
  Asia/Shanghai, a 1280×900 window, 2 GiB of memory, restarted by systemd
  after a crash (tabs lost, profile kept). It doesn't start at boot: the
  first program that needs it runs `systemctl start`, which returns once CDP
  accepts connections. It stops with the VM, and a resident browser doesn't
  keep the VM in use. Noto Sans CJK is installed.
- **The SDK**: `await max.browser()` is the browser's one BrowserContext, and
  `await max.page()` the tab most recently opened or brought to the front,
  opening one if none, by Chromium's own `/json/list` (by activation), since
  `context.pages()` gives later connections the tabs in attach order (and
  once the new-tab page Chromium opens at startup). Then Playwright as usual.
  A program connects once; when it ends it only disconnects, the tabs stay
  for the next, and programs close the tabs they are done with. An action
  waits 10 seconds for its element and a navigation 30 for its page, unless
  the call gives a `timeout`: Playwright's 30 for both made a click on what
  isn't there cost half a minute.
- **Snapshots and refs**: `await max.snapshot(page, {selector?, depth?})` is
  Playwright's `ariaSnapshot({mode: "ai"})` after the title and URL: each
  element carries `[ref=e5]` (`f1e2` in iframes), found with
  `page.locator("aria-ref=e5")`. A ref is of the page's last snapshot, and
  the next program uses it as the one that took the snapshot does, which is
  the SDK's doing: Playwright's refs are numbers its script in the page
  gives elements, and each connection has its own script, which counts
  from e1 again. So `max.snapshot` leaves the tree in the document (a
  property of its window, which goes when the page navigates, as the refs
  do), and a program that connects takes the same snapshot of each tab that
  has one and reads the two side by side: up to the first line that
  differs, a line of each is the same element, and `page.locator` turns the
  ref the model has into the one this connection gives that element. A ref
  after that line, one the snapshot didn't have, and one on a page with no
  snapshot are refused where the locator is made, with what to do, instead
  of Playwright's wait for an element that isn't coming. Lines are compared
  without their refs and without an element's state of the moment
  (`[active]`, `[checked]`). Why is in
  [decisions/resident-chromium.md](../decisions/resident-chromium.md).
- **A program of Max's own**, not run_code's, has the same three with
  `require("/run/max/browser.js")`; it ends with `process.exit()`, since
  the connection keeps Node running.
- **Packaging**: `nix/maxx.nix` bundles the runner, the SDK and
  playwright-core 1.59.0 (no dependencies), and the guest's
  `/run/max/runner.js` links into it.
- **Launch flags are Max's**: `max-browser` appends the lines of
  `/work/.max/chromium-flags` after its own (one a line, blank and `#` lines
  skipped), read at every start; Max writes it and runs `systemctl restart
  max-browser`, which closes the tabs. Extensions load with
  `--load-extension=<dir>`, which nixpkgs' Chromium still accepts (Google
  Chrome dropped it at 137) and which runs under `--headless=new`.
- **Logins**: only Max's own secondary accounts, in the group's profile,
  usable by every program in the group, as the prompt says. In a private
  chat, the other party's own account may be used for them (see
  [Follow-up input](context.md#follow-up-input)).
- Screenshots go to `tools.show`; downloads to `/work`.
- **Detection**: a Chromium Max starts lacks Playwright's automation
  switches (`navigator.webdriver` false, no HeadlessChrome in the User-Agent),
  but the VM's WebGL fingerprint and CDP's traces remain, so Cloudflare-style
  checks block it more readily. Simulated mouse paths and a virtual display
  can come if sites detect it.
- **Third-party site tools**, such as opencli, are Max's to install when
  needed, not pinned in the guest; the prompt mentions it, and that
  `OPENCLI_CDP_ENDPOINT=http://127.0.0.1:9222` makes it use the group's
  browser.
- **Tests**: vm-check starts the browser, opens a data: page, takes a
  snapshot and a screenshot, clicks in the next program by a ref of that
  snapshot, and loads an MV3 extension through the flags
  file and checks its mark on a page. The first start after a boot took 22
  seconds in the nested test (cold store reads over virtiofs under nested
  virtualisation), a second 4.3, a page 0.4; two contexts held 370 to 410 MiB
  anonymous.

## Host-keyed APIs

The host forwards HTTP requests for the VM and adds a key on the way, so
the key never enters the VM, without a host tool per service. Why this shape
is in [decisions/host-keyed-apis.md](../decisions/host-keyed-apis.md).

- **Use**: a program requests `http://127.0.0.1:7777/api/<name>/<path>`;
  max appends the path to the configured `base_url`, inserts the
  key and forwards it, and the response streams back unchanged. curl and
  fetch work; an SDK takes `http://127.0.0.1:7777/api/<name>` as its base URL
  and any key. Anything in the VM may call it, and the host can't tell what.
- **Configuration**:

  ```toml
  [api.resend]
  base_url = "https://api.resend.com"
  secret_file = "/run/secrets/maxx/resend-api-key"
  headers = { Authorization = "Bearer {secret}" }
  allow = ["POST /emails", "GET /emails/*"]
  per_hour = 20
  about = "发邮件，发件人写 max@example.com。文档 https://resend.com/docs/api-reference 。"
  ```

  - `{secret}` in `headers` and `query` is the key, and appears in at least
    one place. Fixed headers (an API version) go in `headers` too. Basic auth
    stores `base64(user:password)` and writes `Authorization = "Basic {secret}"`.
  - `allow` lists `METHOD path`, the method possibly `*`; a `*` segment
    matches one segment, a trailing `**` everything below. Without `allow`,
    everything is allowed. `per_hour` is all the chats' together, counted
    in max's memory, and starts over with max.
  - `about`, with the address, `allow` and `per_hour`, is a line of the system
    prompt per API; without a VM, left out.
  - Names are lowercase letters, digits and `-`. `check-config` checks these
    at build without reading secrets; max reads the secrets at startup and
    won't start without them.
- **What the host enforces**:
  - The normalised path must stay under `base_url`, same origin; paths with
    `%2f`, `%5c` or `%2e` are refused, so the API can't decode them into
    another path around `allow`.
  - The program's `Authorization`, connection headers and `Accept-Encoding`
    aren't forwarded; configured headers override any of the same name.
  - Redirects aren't followed but returned as they are, since following
    would send the key wherever the API pointed (reqwest strips only
    `Authorization`, and only across hosts).
  - A failed connection's error has its URL removed, as the key may be in
    the query.
  - Every call and refusal is logged with the group, API, method, path and
    status, never the body.
  - 10 seconds to connect; the headers and each chunk within 60.
  - The whole request body is read, up to 64 MiB; the program's `Expect`
    header isn't forwarded.
- **What it can't control**: it keeps the key from leaking, not from misuse.
  Anyone who can have Max run commands can have it call these APIs, so they
  suit keys that `allow` and `per_hour` contain, or that the owner leaves to
  Max's judgement. Where control needs the content inspected (who email may go
  to), a host tool is still the way.
- Code: `config::Api`, `config::Rule`, `service/forward/api.rs`.

### GitHub

Max has its own GitHub account, a machine account the owner created
(GitHub requires a responsible person), registered with the owner's
forwarding address, which Max doesn't touch. When someone asks for a PR, Max
forks, clones, pushes, opens it, and later revises it, closes it and answers
comments, with git and the REST API through two keyed APIs. Why not host
tools is in [decisions/host-keyed-apis.md](../decisions/host-keyed-apis.md).

- **The token stays on the host**: whatever is in the VM (environment,
  `~/.config/gh`, a browser login) group members can have read out. It is a
  classic token with only `public_repo`: fine-grained tokens can't open PRs
  on others' repositories. It can't delete repositories or reach private
  ones.
- **`github`**: `https://api.github.com`, with `Authorization: Bearer
  {secret}`, `Accept`, `X-GitHub-Api-Version` and a `User-Agent` (GitHub
  refuses requests without one).
- **`github-git`**: `https://github.com`, git over HTTPS, which takes only
  basic auth, so the secret is `base64("x-access-token:<token>")`
  (`maxx/github-git-auth` in sops), the same token as `maxx/github-token`,
  rotated together. Pushing is `git push
  http://127.0.0.1:7777/api/github-git/<Max>/<repo>.git <branch>`; public
  repositories are cloned from github.com directly. A push's pack can't pass
  64 MiB, and GitHub must answer within 60 seconds.
- Neither sets `allow` or `per_hour`. `about` reminds Max that PRs are opened
  only when someone asks, with a last line in English saying an AI opened it
  at a group member's request, and that GitHub bans accounts that look like
  spam. The host enforces none of it.
- **The committer**: with `[github]` (`login`, `user_id`), the VM's command
  line gets `max.git=<login>,<id>+<login>@users.noreply.github.com`, which
  the guest writes into `/etc/gitconfig`, so commits are the account's and the
  registration address never shows.

## Open

- **Code escaping**: whether GPT should write raw code through Responses'
  custom (freeform) tools, as Codex's code mode does and cliproxy supports;
  and whether the runner should undo Gemini's extra escaping when parsing the
  raw text fails and succeeds without it. How often it goes wrong is being
  watched first.
