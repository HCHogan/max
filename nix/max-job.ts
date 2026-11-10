// max-job: pi's side of one of Max's background jobs, in the groups' VMs,
// where max-pi runs pi in print mode (see "Decoupling from the harness" in
// docs/rust-rewrite.md). It keeps the job's contract with the host, with
// maxx's client (client.js, at MAX_CLIENT), by the job's token in
// MAXX_TOKEN, at MAXX_MCP's host as maxx does:
// - at the end of each turn it takes the steers Max sent meanwhile, which
//   go in before the next model call;
// - when the host says stop, at the job's deadline, it aborts the run;
// - once pi has settled, it reports the last text the agent wrote, and
//   the last model call's error;
// - ask_max asks Max, and waits for the answer.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

type Outcome<T> =
  | { ok: true; value: T }
  | { ok: false; error: { code: string; message: string } };

type Job = {
  turn(): Promise<Outcome<{ steers: string[]; stop: boolean }>>;
  ask(question: string, signal?: AbortSignal): Promise<Outcome<string | null>>;
  stopped(signal: AbortSignal): Promise<boolean>;
  report(report: { text: string | null; error: string | null }): Promise<Outcome<null>>;
};

type Client = { job(options: { url?: string; token?: string }): Job };

const UNANSWERED =
  "Max didn't answer this time. Go on by your own judgement, and say in your report what you assumed.";

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

  pi.registerTool({
    name: "ask_max",
    label: "Ask Max",
    description:
      "Asks Max something only it or the people in the chat know: what they mean, what they prefer, what they left unclear. It waits for Max's answer; without one, go on by your own judgement. Don't ask what you can look up or try out yourself.",
    parameters: Type.Object({
      question: Type.String({
        description: "the question, with the background Max needs to answer it, in full",
      }),
    }),
    executionMode: "sequential",

    async execute(_toolCallId, params, signal) {
      const outcome = await (await job).ask(params.question, signal);
      const answer = outcome.ok ? outcome.value?.trim() : undefined;
      const text = outcome.ok
        ? answer
          ? `Max answered: ${answer}`
          : UNANSWERED
        : `Max couldn't be asked: ${outcome.error.message}. Go on by your own judgement, and say in your report what you assumed.`;
      return { content: [{ type: "text", text }], details: {} };
    },
  });
}
