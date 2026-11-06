// ask_max: a background job's question to Max, for pi in the groups' VMs
// (see "后台 agent" and "和 harness 脱钩" in docs/rust-rewrite.md). It
// asks through the host's /job/ask with maxx's client (client.js, at
// MAX_CLIENT), by the job's token in MAXX_TOKEN, at MAXX_MCP's host as
// maxx does; max wakes Max with it, and the call waits for Max's answer.
// Unanswered in time, the answer is null, and the agent goes on by
// itself. pi's abort withdraws the question.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const UNANSWERED =
  "Max 这次没有答复。按你自己的判断继续，在报告里写明你做了哪些假设。";

type Outcome =
  | { ok: true; value: string | null }
  | { ok: false; error: { code: string; message: string } };

type Client = {
  job(options: { url?: string; token?: string }): {
    ask(question: string, signal?: AbortSignal): Promise<Outcome>;
  };
};

// client.js is CommonJS: its exports, named or as the default.
async function client(): Promise<Client> {
  const loaded = await import(process.env.MAX_CLIENT ?? "");
  return (loaded.job ? loaded : loaded.default) as Client;
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "ask_max",
    label: "Ask Max",
    description:
      "问 Max 一个只有它或群友才知道的问题：他们的意思、偏好、没说清的要求。会等到 Max 答复，等不到就自己判断。能自己查到、试出来的别问。",
    parameters: Type.Object({
      question: Type.String({
        description: "问题，连同 Max 回答要知道的背景，写全",
      }),
    }),
    executionMode: "sequential",

    async execute(_toolCallId, params, signal) {
      const job = (await client()).job({
        url: process.env.MAXX_MCP,
        token: process.env.MAXX_TOKEN,
      });
      const outcome = await job.ask(params.question, signal);
      const answer = outcome.ok ? outcome.value?.trim() : undefined;
      const text = outcome.ok
        ? answer
          ? `Max 答复：${answer}`
          : UNANSWERED
        : `问不了 Max：${outcome.error.message}。按你自己的判断继续，在报告里写明你做了哪些假设。`;
      return { content: [{ type: "text", text }], details: {} };
    },
  });
}
