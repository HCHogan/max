// Runs a few jobs with pi, max-pi.sh and max-job.ts against a fake host,
// and checks that pi keeps the job's contract: steers taken at a turn's
// end go in before the next model call, a stop aborts a tool under way,
// what comes while the host holds the agent about to settle reaches the
// model, the task arrives as written, and the job's system text is
// appended to pi's, and the report goes out before pi exits. Project context files load even with --no-approve,
// but the project's .pi/ stays untrusted. See scripts/check-pi-job.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const [pi] = process.argv.slice(2);
const repo = path.resolve(__dirname, "..");
const TASK = "@小明 帮我查一下\n第二行";
const SYSTEM = "你是测试用的后台 agent。";
const PARENT = "上级目录的约定。";
const PROJECT = "项目自己的构建测试经验。";
const UNTRUSTED = "不该加载的项目系统提示词。";
const SIBLING = "别的项目的约定。";

// What the model says at call `n` of `scenario`: content, and a tool call.
const SCRIPT = {
  steers: n => (n === 1 ? { tool: ["bash", { command: "echo hi" }] } : { content: "完成" }),
  last: n => ({ content: n === 1 ? "初稿" : "定稿" }),
  stop: n => (n === 1 ? { content: "开始查", tool: ["bash", { command: "sleep 30" }] } : { content: "不该到这" }),
  settle: n => ({ content: n === 1 ? "等 Max 回答选哪家" : "订了火锅" }),
  agents: n => (n === 1 ? { tool: ["bash", { command: "pwd" }] } : { content: "项目完成" }),
  claude: n => (n === 1 ? { tool: ["bash", { command: "pwd" }] } : { content: "项目完成" }),
};
// What the turn's end `n` takes.
const STEERS = { steers: ["先看 A", "再看 B"], last: ["再补一句"] };
// What comes to the agent about to settle the first time, after a while.
const ANSWER = "[ask#1 回答] Max\n答：火锅";

// The words of the messages after the model's last answer.
function since(messages) {
  let i = messages.length;
  while (i > 0 && messages[i - 1].role !== "assistant") i--;
  return messages.slice(i).map(message => {
    const content = message.content;
    const text = typeof content === "string" ? content : content.map(part => part.text ?? "").join("");
    return `${message.role}: ${text}`;
  });
}

function host(scenario) {
  const seen = { systems: [], calls: [], turns: 0, settles: 0, reports: [], stops: 0, strangers: [] };
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", chunk => (body += chunk));
    req.on("end", () => {
      const ours = req.url.startsWith("/llm/") || req.url.startsWith("/job/");
      if (ours && req.headers.authorization !== "Bearer the-job-token") seen.strangers.push(req.url);
      if (req.url === "/llm/chat/completions") {
        const request = JSON.parse(body);
        seen.systems.push(request.messages.filter(m => m.role === "system" || m.role === "developer").map(m => m.content).join("\n"));
        seen.calls.push(since(request.messages));
        const { content, tool } = SCRIPT[scenario](seen.calls.length);
        const delta = { role: "assistant", content };
        if (tool) {
          const call = { name: tool[0], arguments: JSON.stringify(tool[1]) };
          delta.tool_calls = [{ index: 0, id: `call_${seen.calls.length}`, type: "function", function: call }];
        }
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.write(`data: ${JSON.stringify({ choices: [{ index: 0, delta }] })}\n\n`);
        const finish = { index: 0, delta: {}, finish_reason: tool ? "tool_calls" : "stop" };
        res.write(`data: ${JSON.stringify({ choices: [finish], usage: { prompt_tokens: 10, completion_tokens: 2 } })}\n\n`);
        return res.end("data: [DONE]\n\n");
      }
      if (req.url === "/job/turn" && JSON.parse(body).settling) {
        seen.settles += 1;
        if (scenario !== "settle" || seen.settles > 1) return res.end('{"steers":[],"stop":false}');
        // Held, with heartbeats, as the host holds an agent whose
        // questions are open.
        res.writeHead(200, { "content-type": "application/x-ndjson" });
        res.write("\n");
        const beat = setInterval(() => res.write("\n"), 300);
        return setTimeout(() => {
          clearInterval(beat);
          res.end(`${JSON.stringify({ steers: [ANSWER], stop: false })}\n`);
        }, 1000);
      }
      if (req.url === "/job/turn") {
        seen.turns += 1;
        const steers = seen.turns === 1 ? (STEERS[scenario] ?? []) : [];
        return res.end(JSON.stringify({ steers, stop: false }));
      }
      if (req.url === "/job/stop") {
        seen.stops += 1;
        res.writeHead(200, { "content-type": "application/x-ndjson" });
        const beat = setInterval(() => res.write("\n"), 500);
        const stop = scenario === "stop" ? setTimeout(() => res.end('{"stop":true}\n'), 1500) : undefined;
        return res.on("close", () => {
          clearInterval(beat);
          clearTimeout(stop);
        });
      }
      if (req.url === "/job/report") {
        seen.reports.push(JSON.parse(body));
        return res.end("{}");
      }
      res.writeHead(404).end();
    });
  });
  return new Promise(resolve => server.listen(0, "127.0.0.1", () => resolve({ server, seen })));
}

// max-pi.sh as the guest runs it, at `port` and with its sessions in `dir`.
async function job(scenario) {
  const { server, seen } = await host(scenario);
  const port = server.address().port;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `pi-job-${scenario}-`));
  for (const sub of ["home", "runtime", "sessions", "work"]) fs.mkdirSync(path.join(dir, sub));
  const work = path.join(dir, "work");
  fs.writeFileSync(path.join(work, "AGENTS.md"), PARENT);
  fs.mkdirSync(path.join(work, "sibling"));
  fs.writeFileSync(path.join(work, "sibling/AGENTS.md"), SIBLING);
  let cwd = work;
  if (scenario === "agents" || scenario === "claude") {
    cwd = path.join(work, "project's directory");
    fs.mkdirSync(path.join(cwd, ".pi/extensions"), { recursive: true });
    fs.writeFileSync(path.join(cwd, scenario === "agents" ? "AGENTS.md" : "CLAUDE.md"), PROJECT);
    fs.writeFileSync(path.join(cwd, ".pi/SYSTEM.md"), UNTRUSTED);
    fs.writeFileSync(path.join(cwd, ".pi/settings.json"), JSON.stringify({ defaultTools: ["read"] }));
    fs.writeFileSync(path.join(cwd, ".pi/extensions/untrusted.js"), 'throw new Error("untrusted extension loaded");');
  }
  const wrapper = fs
    .readFileSync(path.join(repo, "nix/max-pi.sh"), "utf8")
    .replaceAll("127.0.0.1:7777", `127.0.0.1:${port}`)
    .replaceAll("/work/.max/jobs", path.join(dir, "sessions"));
  fs.writeFileSync(path.join(dir, "max-pi.sh"), wrapper);
  const line = JSON.stringify({
    contract: 1, token: "the-job-token", task: TASK, model: "m", api: "openai-completions",
    window: 100000, max_output: null, effort: null, system: SYSTEM,
  });
  const started = Date.now();
  const child = spawn("bash", ["-euo", "pipefail", path.join(dir, "max-pi.sh")], {
    cwd,
    env: {
      ...process.env,
      // Not this machine's skills and settings.
      HOME: path.join(dir, "home"),
      PATH: `${path.dirname(pi)}:${process.env.PATH}`,
      RUNTIME_DIRECTORY: path.join(dir, "runtime"),
      MAX_JOB: path.join(repo, "nix/max-job.ts"),
      MAX_CLIENT: path.join(repo, "nix/client.js"),
      MAXX_MCP: `http://127.0.0.1:${port}/mcp`,
    },
  });
  let out = "";
  let err = "";
  child.stdout.on("data", chunk => (out += chunk));
  child.stderr.on("data", chunk => (err += chunk));
  child.stdin.end(`${line}\n`);
  const killer = setTimeout(() => child.kill("SIGKILL"), 60_000);
  const status = await new Promise(resolve => child.on("close", resolve));
  clearTimeout(killer);
  server.close();
  server.closeAllConnections();
  fs.rmSync(dir, { recursive: true, force: true });
  return { seen, status, out, err, cwd, took: Date.now() - started };
}

function project({ seen, status, cwd, err }) {
  assert.equal(status, 0);
  assert.ok(seen.systems[0].includes(PROJECT), "the project's context file");
  assert.deepEqual(seen.calls[1], [`tool: ${cwd}\n`], "tools use the project's working directory");
  assert.deepEqual(seen.reports, [{ text: "项目完成", error: null }]);
  assert.ok(!err.includes("untrusted extension loaded"), "project extensions stay untrusted");
}

const checks = {
  steers({ seen, status }) {
    assert.equal(status, 0);
    assert.deepEqual(seen.calls[1], ["tool: hi\n", "user: 先看 A", "user: 再看 B"]);
    assert.deepEqual(seen.reports, [{ text: "完成", error: null }]);
    // Once, about to settle, with nothing for it.
    assert.equal(seen.settles, 1);
  },
  last({ seen }) {
    // A steer taken at the last turn's end: pi goes on.
    assert.deepEqual(seen.calls[1], ["user: 再补一句"]);
    assert.deepEqual(seen.reports, [{ text: "定稿", error: null }]);
  },
  stop({ seen }) {
    // Quick, too: sleep 30 was aborted.
    assert.equal(seen.calls.length, 1);
    assert.equal(seen.reports.length, 1);
    assert.equal(seen.reports[0].text, "开始查");
    assert.ok(seen.reports[0].error, "an aborted run says so");
  },
  settle({ seen }) {
    // Held about to settle, it went on with what came, then settled.
    assert.deepEqual(seen.calls[1], [`user: ${ANSWER}`]);
    assert.equal(seen.settles, 2);
    assert.deepEqual(seen.reports, [{ text: "订了火锅", error: null }]);
  },
  agents: project,
  claude: project,
};

(async () => {
  let failed = 0;
  for (const [scenario, check] of Object.entries(checks)) {
    const ran = await job(scenario);
    try {
      assert.deepEqual(ran.seen.calls[0].slice(-1), [`user: ${TASK}`], "the task as written");
      const system = ran.seen.systems[0];
      const at = system.indexOf(SYSTEM);
      assert.ok(at > 0 && system.indexOf(SYSTEM, at + 1) < 0, "the job's system text, once, after pi's");
      assert.ok(system.includes(PARENT), "parent context files load without project trust");
      assert.ok(!system.includes(UNTRUSTED), "project system prompts stay untrusted");
      assert.ok(!system.includes(SIBLING), "other projects' context files don't load");
      assert.deepEqual(ran.seen.strangers, [], "calls without the job's token");
      assert.equal(ran.seen.stops, 1);
      // pi exits only once nothing is left to wait for, the stop stream
      // among them: else this is 60 seconds and a kill.
      assert.ok(ran.took < 15_000, `took ${ran.took} ms`);
      check(ran);
      console.log(`ok   ${scenario} (${ran.took} ms)`);
    } catch (error) {
      failed += 1;
      console.log(`FAIL ${scenario}: ${error.message}`);
      console.log(JSON.stringify({ seen: ran.seen, status: ran.status, out: ran.out, err: ran.err }, null, 2));
    }
  }
  process.exitCode = failed ? 1 : 0;
})();
