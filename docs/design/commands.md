# Commands

Commands are run by the conversation actor itself and never reach the core
(see [The conversation actor](actor.md#state-and-events)); their messages
and replies are entered in the ledger like any other. The parser is
`crates/max/src/command.rs`, the commands are in
`conversation/actor/commands.rs`.

## Syntax

- A command is `/` or a full-width `／` followed by its name; things like
  `/nix/store` aren't commands, and `!` isn't a prefix. In a group a
  command must also @ Max, since other bots there read `/` commands too;
  without the @ it is an ordinary message. A reply to Max doesn't count as
  an @. In a private chat no @ is needed. Help text in groups is written as
  `@maxx /…`.
- QQ's command panel (`/v2/panels`, or "高级设置" in the management console)
  only fills a command into the input box; the user presses send and Max
  gets an ordinary message, so the panel and typing take the same path. The
  panel is the command list, so there is no `/help`. It can't show
  parameter hints and is visible to the whole group. It is registered for
  groups (`scope: group`, `target_type: all`) and changed with
  `PUT /v2/panels/{panel_id}`, not in code: `status` for everyone, `kill`
  for administrators only. Names are without the `/`, which QQ adds; a name
  is at most 7 Chinese characters, a description 15; a panel has at most 20
  items, a bot 20 panels.

## Replies

- A reply looks like a log, so that it is plainly not something Max said in
  a turn: a `text` code block whose first line is the result, with further
  lines below it. It doesn't repeat the command, which is right above it.
  The tone is brief and mechanical, in English: `switched to …`,
  `error: …`, `refused: Max's owners only`. A fence inside the content (a
  persona, say) lengthens the block's fence.
- Replies are marked `系统发的` like the host's error lines (see
  [What the group sees](actor.md#what-the-group-sees)), so the next core
  doesn't take their tone for its own.
- A change that a running turn doesn't see says when it takes effect: with
  no turn running, `takes effect from the next reply`; with one,
  `takes effect when the running turn ends, after 5 minutes idle`, the
  minutes being that turn's idle window. The model and persona are fixed
  when a turn starts (the context is projected for the model's window, and
  the persona is in the system prompt), so `/model`, `/effort` and
  `/persona` take effect from the next turn. `/config` says when its change
  takes effect, which differs by setting.

## Who may run what

| Rank needed | Commands |
| --- | --- |
| Anyone | `/status`; `/model`, `/effort`, `/proactive` and `/persona` without arguments; `/model list`; `/config` without a value; `/clear` (which only asks to confirm) |
| The group owner and administrators | `/kill`, `/stop`, `/start`, changing `/persona`, `/clear --all`, `/unclear`, setting with `/config` |
| Max's owners, or the other party of a private chat | changing `/model`, `/effort`, `/proactive` |
| Max's owners | `/bind`, `/link`, `/unlink` |

Each rank includes those above it. A private chat belongs to the other
party, so they may change its model, effort and proactivity, which affect
only that chat; `/bind`, `/link` and `/unlink` reach beyond it and stay the
owners'. Without the rank the reply is `refused: Max's owners only` or
`refused: the group owner and admins only`. The ranks themselves are in
[Permissions](identity.md#permissions).

## The commands

- **`/status`**: a small card. The first line is maxx and the commit it was
  built from (the flake sets `MAX_COMMIT`; a cargo build says dev). Then
  aligned key-value lines: the VM (below); the model and effort for the
  next reply; proactive replies; `state stopped` after `/stop`; the
  settings the conversation has set, if any
  (`config    idle_window_secs 1800 · call_time_secs 120`); the running turn
  (`t#N · how long · round N`, with its model if it differs from the next
  one's) or `idle`; how often the VM woke Max this hour; the context's
  watermark after `/clear --all`; what this conversation's model calls used
  in the last 24 hours and 7 days, a line each
  (`24h       in 34.2M · out 360k · cache 79.8% · $5.31`: input and output
  tokens, the share of input from the cache, and the cost at list prices;
  `none` without calls); and the uptime of maxx and of the host. The persona
  isn't shown; see `/persona`.
- **The VM in `/status`**:

  ```text
  vm        NixOS 26.05.20261108.ac588ef · x86_64
  memory    1.21G of 7.76G
  /work     264M
  units     web.service · running 3d 4h · 182M · 2 restarts
            poll.timer · waiting 41s
            scrape.service · failed (exit-code) 5m 12s
            new.service · not installed
  ```

  - A running guest is asked (`Vm::about`, `vm/about.rs`): one line over SSH
    reads `/run/current-system/nixos-version`, `/proc/uptime` and
    `/proc/meminfo`, and runs `systemctl show` for the units the files in
    `/work/.max/systemd` name (the names read on the host's side). Memory is
    `MemTotal` less `MemAvailable`, of `MemTotal`. A unit shows its substate,
    how long it has been in it, the memory its processes hold, how often
    systemd restarted it, and how it failed (`Result`); `not installed` for a
    file `maxx units apply` hasn't run over; `bad-setting` or `error` when
    systemd couldn't read it. At most 12 units, then `and N more`. Nothing in
    it is the contract's, so a guest an older max booted answers too.
  - A VM that isn't running isn't started for it: `vm        off`, no
    `memory`, the units by name alone. One that runs and hasn't answered in
    2 seconds is `vm        no answer`.
  - `/work` is counted on the host's side (`vm::taken`), whether or not the
    VM runs, as `du` counts: the blocks under it, a file with several names
    once, no link followed. After 2 seconds it stops at `over 12.3G`.
  - The actor waits for both together, at most those 2 seconds. It waits on
    nothing else of a guest's.
- **`/kill`** ends the running turn quietly (see
  [Cancellation](actor.md#cancellation)) and has the guest stop every
  background command and agent (`maxx units stop-all`, in a task of its
  own); resident units Max keeps run on. No reply: someone stopped it on
  purpose.
- **`/stop`** and **`/start`** leave Max in the chat without replying, and
  bring it back; see [Commands](context.md#commands) in the context's
  design, where what they change is described.
- **`/model`** picks a `provider/model`, `/model list` lists them; **`/effort`**
  sets only the reasoning effort; see [Models](config.md#models).
- **`/proactive on|off`** switches classification of chatter; see
  [Intent](intent.md).
- **`/persona`** shows the persona; with text it sets it; `clear`, `reset`
  and `default` return to the default. The default persona and the rules
  say what to do rather than what not to (a list of don'ts puts each thing
  in front of the model), but for one red-line paragraph in the rules, so it
  stays whatever the persona: Chinese politics, getting around the Great
  Firewall, pornography, gambling, drugs and cults, which get groups and
  accounts banned on QQ; when someone raises them, Max plays dumb and
  changes the subject, or says `[silence]`.
- **`/clear`** asks to confirm; **`/clear --all`** and **`/unclear`** move
  and remove the context's watermark; **`/config`** shows and sets the
  conversation's limits. See [Commands](context.md#commands) and
  [Settings a conversation sets](config.md#settings-a-conversation-sets).
- **`/bind`** joins a QQ group to a conversation; see
  [The official QQ bot](qq.md#groups-and-private-chats).
- **`/link`** and **`/unlink`** let one conversation's Max ask another's;
  see [Asking another conversation](jobs.md#asking-another-conversation).
