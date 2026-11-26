// Runs the guest's fx (nix/fx.sh) with the pinned fx against a fake
// /llm, and checks what Max rests on when it runs fx in a background
// command: a run with no model named calls the agents' default, over
// its protocol, asked to think as hard as max says, with the agent's
// system text after fx's own; another model is named by max's name for
// it, and called over its own protocol; the same --session in the same
// directory goes on with the whole conversation, on another model too,
// and in another is refused before any call; with max out of reach a run goes on with
// what an earlier one was told; and nothing but the model is called.
// See scripts/check-fx.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const [fx] = process.argv.slice(2);
const repo = path.resolve(__dirname, "..");
// How the agent's own system text begins: nix/fx-system.md.
const SYSTEM = "你是 Max 的后台 agent。";
// What max says of its models: the agents' own, by max's name for it,
// which has a / of its own, over Responses as tank's is, and another
// over Chat Completions.
const OWN = { api: "openai-responses", model: "cliproxy/team/model-1", window: 100000, max_output: null };
const OTHER = { api: "openai-chat-completions", model: "local/small", window: 32768, max_output: 4096 };
const ABOUT = { ...OWN, effort: "high", models: [OWN, OTHER] };

// The text of a message, or of an item of a Responses input.
function text(message) {
  const content = message.content ?? "";
  return typeof content === "string" ? content : content.map(part => part.text ?? "").join("");
}

// max's /llm: what it says of the models, while `about` holds, and each
// call answered, over the protocol it came by, with how many calls
// there have been.
function host() {
  const seen = { about: ABOUT, calls: [], strangers: [] };
  const server = http.createServer((req, res) => {
    if (req.method === "GET" && req.url === "/llm") {
      if (!seen.about) return res.writeHead(503).end();
      return res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(seen.about));
    }
    let body = "";
    req.on("data", chunk => (body += chunk));
    req.on("end", () => {
      const api = { "/llm/responses": "openai-responses", "/llm/chat/completions": "openai-chat-completions" }[req.url];
      if (req.method !== "POST" || !api) {
        seen.strangers.push(`${req.method} ${req.url}`);
        return res.writeHead(404).end();
      }
      const request = JSON.parse(body);
      const responses = api === "openai-responses";
      const messages = responses ? request.input : request.messages;
      const own = m => m.role === "system" || m.role === "developer";
      const system = [request.instructions ?? "", ...messages.filter(own).map(text)].join("\n");
      const said = messages.filter(m => !own(m)).map(m => `${m.role}: ${text(m)}`);
      const effort = (responses ? request.reasoning?.effort : request.reasoning_effort) ?? null;
      seen.calls.push({ api, model: request.model, effort, system, said });
      const answer = `第 ${seen.calls.length} 次`;
      res.writeHead(200, { "content-type": "text/event-stream" });
      if (responses) {
        const item = { type: "message", id: "msg_1", role: "assistant", status: "completed", content: [{ type: "output_text", text: answer, annotations: [] }] };
        const usage = { input_tokens: 1, output_tokens: 1, total_tokens: 2 };
        const events = [
          { type: "response.created", response: { id: "resp_1", status: "in_progress", output: [] } },
          { type: "response.output_item.added", output_index: 0, item: { ...item, status: "in_progress", content: [] } },
          { type: "response.output_text.delta", item_id: item.id, output_index: 0, content_index: 0, delta: answer },
          { type: "response.output_item.done", output_index: 0, item },
          { type: "response.completed", response: { id: "resp_1", status: "completed", output: [item], usage } },
        ];
        for (const event of events) res.write(`event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`);
        return res.end();
      }
      const delta = { role: "assistant", content: answer };
      res.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta }] })}\n\n`);
      res.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\n`);
      res.end("data: [DONE]\n\n");
    });
  });
  return new Promise(resolve => server.listen(0, "127.0.0.1", () => resolve({ server, seen })));
}

// nix/fx.sh as the guest has it, with max at `port`, run in `cwd` with
// `args`, as a background command runs it: no input.
async function run(dir, port, cwd, args) {
  const wrapper = path.join(dir, "fx.sh");
  if (!fs.existsSync(wrapper)) {
    const script = fs.readFileSync(path.join(repo, "nix/fx.sh"), "utf8").replaceAll("127.0.0.1:7777", `127.0.0.1:${port}`);
    fs.writeFileSync(wrapper, script);
  }
  const child = spawn("bash", ["-euo", "pipefail", wrapper, ...args], {
    cwd,
    env: {
      ...process.env,
      // Not this machine's sessions and settings.
      HOME: path.join(dir, "home"),
      FX_BIN: fx,
      FX_SYSTEM: path.join(repo, "nix/fx-system.md"),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let out = "";
  let err = "";
  child.stdout.on("data", chunk => (out += chunk));
  child.stderr.on("data", chunk => (err += chunk));
  const killer = setTimeout(() => child.kill("SIGKILL"), 60_000);
  const status = await new Promise(resolve => child.on("close", resolve));
  clearTimeout(killer);
  return { status, out, err };
}

(async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-fx-"));
  const work = path.join(dir, "work");
  const elsewhere = path.join(dir, "elsewhere");
  for (const sub of [path.join(dir, "home"), work, elsewhere]) fs.mkdirSync(sub, { recursive: true });
  const { server, seen } = await host();
  const port = server.address().port;
  const last = () => seen.calls.at(-1);
  const steps = [
    ["the default model", async () => {
      const ran = await run(dir, port, work, ["ask", "--session", "task-1", "第一句"]);
      assert.equal(ran.status, 0, ran.err);
      assert.equal(ran.out.trim(), "第 1 次", "what it said on stdout");
      assert.deepEqual([last().api, last().model, last().effort], [OWN.api, OWN.model, "high"], "the agents' own, asked to think as max says");
      const at = last().system.indexOf(SYSTEM);
      assert.ok(at > 0 && last().system.indexOf(SYSTEM, at + 1) < 0, "the agent's system text, once, after fx's");
    }],
    ["going on", async () => {
      const ran = await run(dir, port, work, ["ask", "--session", "task-1", "第二句"]);
      assert.equal(ran.status, 0, ran.err);
      assert.deepEqual(last().said, ["user: 第一句", "assistant: 第 1 次", "user: 第二句"], "the whole conversation");
    }],
    ["another model", async () => {
      const ran = await run(dir, port, work, ["ask", "--model", OTHER.model, "--effort", "low", "问"]);
      assert.equal(ran.status, 0, ran.err);
      assert.deepEqual([last().api, last().model, last().effort], [OTHER.api, OTHER.model, "low"], "by max's name, over its protocol, as hard as asked");
      assert.deepEqual(last().said, ["user: 问"], "a run without a name is nobody's session");
    }],
    ["going on, on another model", async () => {
      const ran = await run(dir, port, work, ["ask", "--session", "task-1", "--model", OTHER.model, "第三句"]);
      assert.equal(ran.status, 0, ran.err);
      assert.deepEqual([last().api, last().model], [OTHER.api, OTHER.model], "over the other protocol");
      assert.deepEqual(last().said.slice(-3), ["user: 第二句", "assistant: 第 2 次", "user: 第三句"], "the whole conversation");
    }],
    ["the session elsewhere", async () => {
      const calls = seen.calls.length;
      const ran = await run(dir, port, elsewhere, ["ask", "--session", "task-1", "第四句"]);
      assert.equal(ran.status, 2);
      assert.ok(ran.err.includes(`the session task-1 is in ${fs.realpathSync(work)}`), ran.err);
      assert.equal(seen.calls.length, calls, "no call");
    }],
    ["a name that is no file's", async () => {
      const calls = seen.calls.length;
      const ran = await run(dir, port, work, ["ask", "--session", "../task-1", "第四句"]);
      assert.equal(ran.status, 2, ran.err);
      assert.equal(seen.calls.length, calls, "no call");
    }],
    ["the models", async () => {
      const ran = await run(dir, port, work, ["models"]);
      assert.equal(ran.status, 0, ran.err);
      assert.deepEqual(ran.out.trim().split("\n"), [`${OWN.model}\t100000 tokens\tdefault`, `${OTHER.model}\t32768 tokens`]);
    }],
    ["max out of reach", async () => {
      seen.about = null;
      const ran = await run(dir, port, work, ["ask", "又问"]);
      assert.equal(ran.status, 0, ran.err);
      assert.deepEqual([last().model, last().effort], [OWN.model, "high"], "what an earlier run was told");
    }],
    ["no effort", async () => {
      seen.about = { ...ABOUT, effort: null };
      const ran = await run(dir, port, work, ["ask", "再问"]);
      assert.equal(ran.status, 0, ran.err);
      assert.equal(last().effort, null, "none asked for");
    }],
  ];
  let failed = 0;
  for (const [name, step] of steps) {
    try {
      await step();
      console.log(`ok   ${name}`);
    } catch (error) {
      failed += 1;
      console.log(`FAIL ${name}: ${error.message}`);
    }
  }
  try {
    assert.deepEqual(seen.strangers, [], "calls of anything but the model");
  } catch (error) {
    failed += 1;
    console.log(`FAIL ${error.message}`);
  }
  server.close();
  server.closeAllConnections();
  fs.rmSync(dir, { recursive: true, force: true });
  process.exitCode = failed ? 1 : 0;
})();
