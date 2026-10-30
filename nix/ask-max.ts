// ask_max: a background job's question to Max, for pi in the groups' VMs
// (see "后台 agent" in docs/rust-rewrite.md). The question is an input
// dialog, which pi's RPC hands to max; max wakes Max with it, and Max's
// answer comes back as the dialog's value. Unanswered in time, max
// cancels the dialog, and the agent goes on by itself.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const UNANSWERED =
  "Max 这次没有答复。按你自己的判断继续，在报告里写明你做了哪些假设。";

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

    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      const answer = (await ctx.ui.input(params.question, ""))?.trim();
      const text = answer ? `Max 答复：${answer}` : UNANSWERED;
      return { content: [{ type: "text", text }], details: {} };
    },
  });
}
