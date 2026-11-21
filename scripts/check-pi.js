// Runs the guest's pi (nix/pi.sh) with the pinned pi against a fake
// /llm, and checks what Max rests on when it runs pi in a background
// command: a run with no model named calls the agents' default, asked
// to think as hard as max says, with the agent's system text after pi's
// own; another model is named by max's name for it; the same
// --session-id in the same directory goes on with the whole
// conversation, and in another is refused before any call; with max out
// of reach a run goes on with what an earlier one wrote; and what else
// is in pi's files is kept. See scripts/check-pi.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const [pi] = process.argv.slice(2);
const repo = path.resolve(__dirname, "..");
// How the agent's own system text begins: nix/pi-system.md.
const SYSTEM = "你是 Max 的后台 agent。";
// What max says of its models: the agents' own, by max's name for it,
// which has a / of its own, and another.
const OWN = "cliproxy/team/model-1";
const OTHER = "local/small";
const ABOUT = {
  api: "openai-completions",
  model: OWN,
  window: 100000,
  max_output: null,
  effort: "high",
  models: [
    { api: "openai-completions", model: OWN, window: 100000, max_output: null },
    { api: "openai-completions", model: OTHER, window: 32768, max_output: 4096 },
  ],
};

// Who said what in a message.
function words(message) {
  const content = message.content ?? "";
  const text = typeof content === "string" ? content : content.map(part => part.text ?? "").join("");
  return `${message.role}: ${text}`;
}

// max's /llm: what it says of the models, while `about` holds, and each
// call answered with how many messages it was sent.
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
      if (req.url !== "/llm/chat/completions") {
        seen.strangers.push(req.url);
        return res.writeHead(404).end();
      }
      const request = JSON.parse(body);
      const system = request.messages.filter(m => m.role === "system" || m.role === "developer").map(m => m.content).join("\n");
      const said = request.messages.filter(m => m.role !== "system" && m.role !== "developer").map(words);
      seen.calls.push({ model: request.model, effort: request.reasoning_effort ?? null, system, said });
      const delta = { role: "assistant", content: `第 ${seen.calls.length} 次` };
      res.writeHead(200, { "content-type": "text/event-stream" });
      res.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta }] })}\n\n`);
      res.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\n`);
      res.end("data: [DONE]\n\n");
    });
  });
  return new Promise(resolve => server.listen(0, "127.0.0.1", () => resolve({ server, seen })));
}

// nix/pi.sh as the guest has it, with max at `port`, run in `cwd` with
// `args`, as a background command runs it: no input.
async function run(dir, port, cwd, args) {
  const wrapper = path.join(dir, "pi.sh");
  if (!fs.existsSync(wrapper)) {
    const text = fs.readFileSync(path.join(repo, "nix/pi.sh"), "utf8").replaceAll("127.0.0.1:7777", `127.0.0.1:${port}`);
    fs.writeFileSync(wrapper, text);
  }
  const child = spawn("bash", ["-euo", "pipefail", wrapper, ...args], {
    cwd,
    env: {
      ...process.env,
      // Not this machine's skills and settings.
      HOME: path.join(dir, "home"),
      PI_BIN: pi,
      PI_SYSTEM: path.join(repo, "nix/pi-system.md"),
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
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-pi-"));
  const agent = path.join(dir, "home/.pi/agent");
  const work = path.join(dir, "work");
  const elsewhere = path.join(dir, "elsewhere");
  for (const sub of [agent, work, elsewhere]) fs.mkdirSync(sub, { recursive: true });
  // What someone else put in pi's files.
  fs.writeFileSync(path.join(agent, "models.json"), JSON.stringify({ providers: { mine: { baseUrl: "http://127.0.0.1:1/v1", api: "openai-completions", apiKey: "x", models: [{ id: "m" }] } } }));
  fs.writeFileSync(path.join(agent, "settings.json"), JSON.stringify({ theme: "light" }));
  const { server, seen } = await host();
  const port = server.address().port;
  const steps = [
    ["the default model", async () => {
      const ran = await run(dir, port, work, ["-p", "--session-id", "task-1", "第一句"]);
      assert.equal(ran.status, 0, ran.err);
      assert.equal(ran.out.trim(), "第 1 次", "the last text on stdout");
      const call = seen.calls.at(-1);
      assert.deepEqual([call.model, call.effort], [OWN, "high"], "the agents' own, asked to think as max says");
      const at = call.system.indexOf(SYSTEM);
      assert.ok(at > 0 && call.system.indexOf(SYSTEM, at + 1) < 0, "the agent's system text, once, after pi's");
      const models = JSON.parse(fs.readFileSync(path.join(agent, "models.json"), "utf8"));
      assert.deepEqual(Object.keys(models.providers).sort(), ["max", "mine"], "another's provider is kept");
      assert.equal(JSON.parse(fs.readFileSync(path.join(agent, "settings.json"), "utf8")).theme, "light", "another's setting is kept");
    }],
    ["going on", async () => {
      const ran = await run(dir, port, work, ["-p", "--session-id", "task-1", "第二句"]);
      assert.equal(ran.status, 0, ran.err);
      assert.deepEqual(seen.calls.at(-1).said, ["user: 第一句", "assistant: 第 1 次", "user: 第二句"], "the whole conversation");
    }],
    ["another model", async () => {
      const ran = await run(dir, port, work, ["-p", "--no-session", "--model", OTHER, "--thinking", "off", "问"]);
      assert.equal(ran.status, 0, ran.err);
      assert.deepEqual([seen.calls.at(-1).model, seen.calls.at(-1).effort], [OTHER, null], "by max's name, asked for no effort");
    }],
    ["the session elsewhere", async () => {
      const calls = seen.calls.length;
      const ran = await run(dir, port, elsewhere, ["-p", "--session-id", "task-1", "第三句"]);
      assert.equal(ran.status, 2);
      assert.ok(ran.err.includes(`the session task-1 is in ${fs.realpathSync(work)}`), ran.err);
      assert.equal(seen.calls.length, calls, "no call");
    }],
    ["max out of reach", async () => {
      seen.about = null;
      const ran = await run(dir, port, work, ["-p", "--no-session", "又问"]);
      assert.equal(ran.status, 0, ran.err);
      assert.deepEqual([seen.calls.at(-1).model, seen.calls.at(-1).effort], [OWN, "high"], "what an earlier run wrote");
    }],
    ["no effort", async () => {
      seen.about = { ...ABOUT, effort: null };
      const ran = await run(dir, port, work, ["-p", "--no-session", "再问"]);
      assert.equal(ran.status, 0, ran.err);
      assert.equal(seen.calls.at(-1).effort, null, "none asked for");
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
