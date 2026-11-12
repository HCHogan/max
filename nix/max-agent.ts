// max-agent: pi's side of one of Max's background agents, in the groups'
// VMs, where max-pi runs pi in print mode as a unit of the guest's (see
// "Background agents" in docs/rust-rewrite.md). The agent's whole life is
// that unit's; max keeps nothing of it. What this plugin keeps, with files
// in the agent's directory, MAX_AGENT_DIR (/run/max/jobs/<unit>):
// - at the end of each turn it takes the steers in `inbox`, which
//   `max-agent steer` put there, and they go in before the next model
//   call;
// - as pi is about to settle, it takes them once more: if the agent has
//   asked its Max something (`max-agent ask` left `asked`) and nothing has
//   come, it waits a while for an answer, and what comes is one more
//   turn's input;
// - a few minutes before the unit's limit it tells the agent to wrap up;
// - on SIGUSR2, the unit's KillSignal, at its limit or when it is
//   stopped, it aborts the run and leaves `stopped`: pi itself would exit
//   at once on SIGTERM, with nothing reported;
// - once pi has settled, it writes the last text the agent wrote as its
//   report, and the last model call's error, if it failed, in `error`.
// The unit's ExecStopPost (max-jobs ended) tells Max of the end from
// those.
import * as fs from "node:fs";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const name = process.env.MAX_AGENT ?? "";
const dir = process.env.MAX_AGENT_DIR ?? "";
const reports = process.env.MAX_AGENT_REPORTS ?? "/work/.max/jobs";
const inbox = `${dir}/inbox`;
// How long an agent with nothing left to do but wait for an answer waits.
const HOLD = Number(process.env.MAX_AGENT_HOLD_MS ?? 10 * 60_000);
// How long before its limit it is told to stop working and report:
// stopped with a tool call under way, it has no text to give.
const WARNING = 5 * 60_000;
const WRAP_UP = "还剩 5 分钟就到点了。别再查新的：现在先更新笔记，再把已经查到的写成报告交给 Max，没做完的写明做到哪了。";

const read = (file: string): string | null => {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return null;
  }
};

// The steers in the inbox, oldest first, each gone from it once taken.
// One still being written has a dot before its name.
function taken(): string[] {
  let names: string[] = [];
  try {
    names = fs.readdirSync(inbox).filter(name => !name.startsWith("."));
  } catch {
    return [];
  }
  const steers: string[] = [];
  for (const name of names.sort()) {
    const steer = read(`${inbox}/${name}`);
    fs.rmSync(`${inbox}/${name}`, { force: true });
    if (steer?.trim()) steers.push(steer);
  }
  return steers;
}

const waiting = (): boolean => {
  try {
    return fs.readdirSync(inbox).some(name => !name.startsWith("."));
  } catch {
    return false;
  }
};

// What an assistant message wrote, without its reasoning or tool calls.
function written(message: { content?: unknown }): string {
  const content = Array.isArray(message.content) ? message.content : [];
  return content
    .filter(part => part?.type === "text")
    .map(part => part.text)
    .join("")
    .trim();
}

export default function (pi: ExtensionAPI) {
  // The latest context pi handed over, to abort with.
  let ctx: ExtensionContext | undefined;
  let stopping = false;
  let text: string | null = null;
  let error: string | null = null;
  let reported = false;

  const stop = () => {
    stopping = true;
    try {
      fs.writeFileSync(`${dir}/stopped`, "");
    } catch {}
    ctx?.abort();
  };
  process.on("SIGUSR2", stop);

  // The wrap-up, as a steer of its own: its name sorts after Max's.
  const started = Number(read(`${dir}/started`)) * 1000;
  const limit = Number(read(`${dir}/limit`)) * 1000;
  const until = started + limit - WARNING - Date.now();
  const timer = until > 0 ? setTimeout(() => fs.writeFileSync(`${inbox}/wrap-up`, WRAP_UP), until) : undefined;
  // pi exits only once nothing is left to wait for.
  timer?.unref();

  // Until a steer waits in the inbox, the agent is stopped, or ms pass.
  const comes = (ms: number) =>
    new Promise<void>(resolve => {
      const done = () => {
        clearInterval(looking);
        clearTimeout(over);
        resolve();
      };
      const looking = setInterval(() => (stopping || waiting()) && done(), 250);
      const over = setTimeout(done, ms);
    });

  pi.on("agent_start", (_event, context) => {
    ctx = context;
  });

  pi.on("turn_start", (_event, context) => {
    ctx = context;
  });

  pi.on("message_end", event => {
    const message = event.message;
    if (message.role !== "assistant") return;
    const wrote = written(message);
    if (wrote) text = wrote;
    error = message.stopReason === "error" ? (message.errorMessage ?? "the model call failed") : null;
  });

  // pi takes the steers in once this has run, before the next call.
  pi.on("turn_end", () => {
    if (stopping) return;
    for (const steer of taken()) pi.sendUserMessage(steer, { deliverAs: "steer" });
  });

  // pi is about to settle. What comes goes in as Max's words, and pi
  // runs once more.
  pi.on("agent_before_settle", async event => {
    if (stopping) return;
    let steers = taken();
    if (steers.length === 0 && fs.existsSync(`${dir}/asked`)) {
      await comes(HOLD);
      steers = taken();
    }
    fs.rmSync(`${dir}/asked`, { force: true });
    if (stopping || steers.length === 0) return;
    const said = steers.map(content => ({ type: "custom_message" as const, customType: "max", content, display: true }));
    return { entries: [...event.entries, ...said], continue: true };
  });

  // pi waits for this before it exits.
  pi.on("agent_settled", () => {
    if (reported) return;
    reported = true;
    clearTimeout(timer);
    if (text) {
      const title = (read(`${dir}/title`) ?? "").trim();
      fs.mkdirSync(reports, { recursive: true });
      fs.writeFileSync(`${reports}/${name}.md`, `# ${name} ${title}\n\n${text}\n`);
    }
    if (error && !stopping) fs.writeFileSync(`${dir}/error`, error);
  });

  pi.on("session_shutdown", () => {
    clearTimeout(timer);
  });
}
