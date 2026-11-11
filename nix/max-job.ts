// max-job: pi's side of one of Max's background jobs, in the groups' VMs,
// where max-pi runs pi in print mode (see "Decoupling from the harness" in
// docs/rust-rewrite.md). It keeps the job's contract with the host, with
// maxx's client (client.js, at MAX_CLIENT), by the job's token in
// MAXX_TOKEN, at MAXX_MCP's host as maxx does:
// - at the end of each turn it takes the steers Max sent meanwhile, which
//   go in before the next model call;
// - as pi is about to settle, it takes them once more: with the agent's
//   questions (Max's ask tool) still open, the host holds the call until
//   an answer or a steer comes, and what comes is one more turn's input;
// - when the host says stop, at the job's deadline, it aborts the run;
// - once pi has settled, it reports the last text the agent wrote, and
//   the last model call's error.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

type Outcome<T> =
  | { ok: true; value: T }
  | { ok: false; error: { code: string; message: string } };

type Job = {
  turn(options?: { settling?: boolean }): Promise<Outcome<{ steers: string[]; stop: boolean }>>;
  stopped(signal: AbortSignal): Promise<boolean>;
  report(report: { text: string | null; error: string | null }): Promise<Outcome<null>>;
};

type Client = { job(options: { url?: string; token?: string }): Job };

// client.js is CommonJS: its exports, named or as the default.
async function connect(): Promise<Job> {
  const loaded = await import(process.env.MAX_CLIENT ?? "");
  const client = (loaded.job ? loaded : loaded.default) as Client;
  return client.job({ url: process.env.MAXX_MCP, token: process.env.MAXX_TOKEN });
}

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
  const job = connect();
  // The latest context pi handed over, to abort with.
  let ctx: ExtensionContext | undefined;
  let stopping = false;
  let watching: AbortController | undefined;
  let text: string | null = null;
  let error: string | null = null;
  let reported = false;

  const stop = () => {
    stopping = true;
    ctx?.abort();
  };

  pi.on("agent_start", (_event, context) => {
    ctx = context;
    if (watching) return;
    watching = new AbortController();
    const signal = watching.signal;
    void job.then(job => job.stopped(signal)).then(said => said && stop());
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
  pi.on("turn_end", async () => {
    if (stopping) return;
    const outcome = await (await job).turn();
    if (!outcome.ok) return;
    if (outcome.value.stop) return stop();
    for (const steer of outcome.value.steers) pi.sendUserMessage(steer, { deliverAs: "steer" });
  });

  // pi is about to settle. What comes goes in as Max's words, and pi
  // runs once more.
  pi.on("agent_before_settle", async event => {
    if (stopping) return;
    const outcome = await (await job).turn({ settling: true });
    if (!outcome.ok) return;
    if (outcome.value.stop) return stop();
    const steers = outcome.value.steers;
    if (steers.length === 0) return;
    const said = steers.map(content => ({ type: "custom_message" as const, customType: "max", content, display: true }));
    return { entries: [...event.entries, ...said], continue: true };
  });

  // pi waits for this before it exits.
  pi.on("agent_settled", async () => {
    if (reported) return;
    reported = true;
    watching?.abort();
    await (await job).report({ text, error });
  });

  // pi exits only once nothing is left to wait for.
  pi.on("session_shutdown", () => {
    watching?.abort();
  });
}
