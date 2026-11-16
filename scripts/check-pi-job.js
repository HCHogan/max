// Runs a few agents with pi, max-pi.sh and max-agent.ts against a fake
// /llm, and checks that pi keeps what the plugin rests on: steers taken
// from the inbox at a turn's end go in before the next model call,
// SIGUSR2 aborts a tool under way and the report is still written, what
// comes while the plugin holds an agent about to settle reaches the model,
// the task arrives as written, the agent's system text, with its notes,
// is appended to pi's, and its session is named after its unit and
// titled as Max titled it. One that takes up an earlier agent's session
// has all of it, the earlier left as it was, on its own model and with
// its own system text. Project context files load even with
// --no-approve, but the project's .pi/ stays untrusted. See
// scripts/check-pi-job.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const [pi] = process.argv.slice(2);
const repo = path.resolve(__dirname, "..");
const UNIT = "max-agent-1";
const TASK = "@小明 帮我查一下\n第二行";
// The agent one takes up, `maxx agent start --resume`: its task, its
// model and how hard it thought, all unlike the one's that takes it up.
const EARLIER = { unit: "max-agent-0", task: "先查 foo", title: "旧标题", model: "cliproxy/old-model", effort: "low" };
// The agent's model, as max names one: `provider/model`, and the model's
// own name may have a / as well.
const MODEL = "cliproxy/team/model-1";
// How hard Max told an agent to think: `maxx agent start --effort`.
const EFFORT = { steers: "high", last: "xhigh", resume: "high" };
// How the agent's own system text begins: nix/agent-system.md.
const SYSTEM = "你是 Max 的后台 agent。";
// With what bash would take for the match in a substitution.
const NOTES = "上次核实过：用 make build && make test 跑测试。";
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
  answered: n => (n === 1 ? { tool: ["bash", { command: "echo hi" }] } : { content: "订了火锅" }),
  agents: n => (n === 1 ? { tool: ["bash", { command: "pwd" }] } : { content: "项目完成" }),
  claude: n => (n === 1 ? { tool: ["bash", { command: "pwd" }] } : { content: "项目完成" }),
  earlier: n => (n === 1 ? { tool: ["bash", { command: "echo foo is 42" }] } : { content: "foo 是 42" }),
  resume: () => ({ content: "bar 也查了" }),
};
// What comes to the agent about to settle, after a while: it had asked.
const ANSWER = "[回答] 火锅";
// How long the plugin holds an agent that waits for an answer.
const HOLD = 20_000;
// What waits in the inbox as the agent starts.
const STEERS = { steers: ["先看 A", "再看 B"], last: ["再补一句"], answered: [ANSWER] };

// Who said what in a message.
function words(message) {
  const content = message.content ?? "";
  const text = typeof content === "string" ? content : content.map(part => part.text ?? "").join("");
  return `${message.role}: ${text}`;
}

// The words of the messages after the model's last answer.
function since(messages) {
  let i = messages.length;
  while (i > 0 && messages[i - 1].role !== "assistant") i--;
  return messages.slice(i).map(words);
}

function host(scenario) {
  const seen = { systems: [], calls: [], whole: [], asked: [], strangers: [] };
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", chunk => (body += chunk));
    req.on("end", () => {
      if (req.url !== "/llm/chat/completions") {
        seen.strangers.push(req.url);
        return res.writeHead(404).end();
      }
      const request = JSON.parse(body);
      seen.systems.push(request.messages.filter(m => m.role === "system" || m.role === "developer").map(m => m.content).join("\n"));
      seen.calls.push(since(request.messages));
      seen.whole.push(request.messages.filter(m => m.role !== "system" && m.role !== "developer").map(words));
      // The model it calls, and how hard it asks it to think.
      seen.asked.push([request.model, request.reasoning_effort ?? null]);
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
      res.end("data: [DONE]\n\n");
    });
  });
  return new Promise(resolve => server.listen(0, "127.0.0.1", () => resolve({ server, seen })));
}

// The agents' notes for `cwd`, named as max-pi.sh names them.
function notesName(cwd) {
  const name = path.resolve(cwd).replace(/^\//, "").replace(/[^\p{L}\p{N}]/gu, "-").slice(0, 120);
  return `${name}.md`;
}

// The entries of a session pi wrote.
const entries = file =>
  fs
    .readFileSync(file, "utf8")
    .split("\n")
    .filter(line => line.trim())
    .map(line => JSON.parse(line));

// Once `ready` holds, and `ms` more.
function after(ready, ms, then) {
  const looking = setInterval(() => {
    if (!ready()) return;
    clearInterval(looking);
    setTimeout(then, ms);
  }, 50);
  return looking;
}

// What `maxx agent start` leaves for `unit` in the guest's directories,
// `dir`: its directory under /run/max/jobs.
function prepare(dir, unit, { task, cwd, title, model, effort }) {
  const jobs = path.join(dir, "jobs", unit);
  fs.mkdirSync(path.join(jobs, "inbox"), { recursive: true });
  fs.writeFileSync(path.join(jobs, "task"), `${task}\n`);
  fs.writeFileSync(path.join(jobs, "workdir"), `${cwd}\n`);
  fs.writeFileSync(path.join(jobs, "title"), `${title}\n`);
  fs.writeFileSync(path.join(jobs, "started"), `${Math.floor(Date.now() / 1000)}\n`);
  fs.writeFileSync(path.join(jobs, "limit"), "21600\n");
  // The model as max names it, its provider first, and how hard Max
  // would have it think.
  fs.writeFileSync(path.join(jobs, "model.json"), JSON.stringify({ api: "openai-completions", model, window: 100000, max_output: null, effort }));
  return jobs;
}

// max-pi.sh as the guest's unit runs it, with max at `port` and the
// guest's directories in `dir`. What `meanwhile` does to the process
// while it runs, it does with timers, which it returns.
async function run(dir, unit, port, meanwhile = () => []) {
  const wrapper = fs
    .readFileSync(path.join(repo, "nix/max-pi.sh"), "utf8")
    .replaceAll("127.0.0.1:7777", `127.0.0.1:${port}`)
    .replaceAll("/run/max/jobs", path.join(dir, "jobs"))
    .replaceAll("/work/.max/jobs", path.join(dir, "sessions"))
    .replaceAll("/work/.max/projects", path.join(dir, "projects"));
  fs.writeFileSync(path.join(dir, "max-pi.sh"), wrapper);
  const started = Date.now();
  const child = spawn("bash", ["-euo", "pipefail", path.join(dir, "max-pi.sh"), unit], {
    cwd: dir,
    env: {
      ...process.env,
      // Not this machine's skills and settings.
      HOME: path.join(dir, "home"),
      PATH: `${path.dirname(pi)}:${process.env.PATH}`,
      RUNTIME_DIRECTORY: path.join(dir, "runtime"),
      MAX_AGENT_PLUGIN: path.join(repo, "nix/max-agent.ts"),
      MAX_AGENT_SYSTEM: path.join(repo, "nix/agent-system.md"),
      MAX_AGENT_HOLD_MS: `${HOLD}`,
    },
  });
  let out = "";
  let err = "";
  child.stdout.on("data", chunk => (out += chunk));
  child.stderr.on("data", chunk => (err += chunk));
  child.stdin.end();
  const timers = meanwhile(child);
  const killer = setTimeout(() => child.kill("SIGKILL"), 60_000);
  const status = await new Promise(resolve => child.on("close", resolve));
  clearTimeout(killer);
  timers.forEach(clearInterval);
  return { status, out, err, took: Date.now() - started };
}

// The session pi keeps for `unit` in `dir`, by its name.
const sessionOf = (dir, unit) => fs.readdirSync(path.join(dir, "sessions")).find(name => name.endsWith(`_${unit}.jsonl`));

// An agent that ended, in `dir`, working in `cwd`: the one taken up.
async function earlier(dir, cwd) {
  const { server, seen } = await host("earlier");
  prepare(dir, EARLIER.unit, { ...EARLIER, cwd });
  const ran = await run(dir, EARLIER.unit, server.address().port);
  server.close();
  server.closeAllConnections();
  assert.equal(ran.status, 0, ran.err);
  assert.deepEqual(seen.asked.at(-1), [EARLIER.model, EARLIER.effort]);
  const file = path.join(dir, "sessions", sessionOf(dir, EARLIER.unit));
  return { file, kept: fs.readFileSync(file, "utf8") };
}

async function agent(scenario) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), `pi-agent-${scenario}-`));
  for (const sub of ["home", "runtime", "sessions", "projects", "work"]) fs.mkdirSync(path.join(dir, sub));
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
  // Ended before notes for its directory were written.
  const taken = scenario === "resume" ? await earlier(dir, cwd) : null;
  const { server, seen } = await host(scenario);
  const jobs = prepare(dir, UNIT, { task: TASK, cwd, title: "试试", model: MODEL, effort: EFFORT[scenario] ?? null });
  // What maxx agent start --resume found.
  if (taken) fs.writeFileSync(path.join(jobs, "resume"), `${taken.file}\n`);
  (STEERS[scenario] ?? []).forEach((steer, n) => fs.writeFileSync(path.join(jobs, "inbox", `${n}`), `${steer}\n`));
  if (scenario === "steers" || scenario === "resume") fs.writeFileSync(path.join(dir, "projects", notesName(cwd)), `${NOTES}\n`);
  // As after `maxx agent ask`: the agent waits for its answer.
  if (scenario === "settle" || scenario === "answered") fs.writeFileSync(path.join(jobs, "asked"), "");
  const called = () => seen.calls.length >= 1;
  const { status, out, err, took } = await run(dir, UNIT, server.address().port, child => {
    // The unit's KillSignal, while the tool runs: max-pi execs pi.
    if (scenario === "stop") return [after(called, 1500, () => child.kill("SIGUSR2"))];
    // Max's answer, once the agent is held about to settle.
    if (scenario === "settle") return [after(called, 1500, () => fs.writeFileSync(path.join(jobs, "inbox", "9"), `${ANSWER}\n`))];
    return [];
  });
  server.close();
  server.closeAllConnections();
  const read = file => {
    try {
      return fs.readFileSync(file, "utf8");
    } catch {
      return null;
    }
  };
  const session = sessionOf(dir, UNIT);
  const kept = session ? entries(path.join(dir, "sessions", session)) : [];
  const ran = {
    seen, status, out, err, cwd, took,
    // The sessions there are, but the one taken up, and what this one's says.
    sessions: fs.readdirSync(path.join(dir, "sessions")).filter(name => name.endsWith(".jsonl") && !name.endsWith(`_${EARLIER.unit}.jsonl`)),
    header: kept[0],
    titles: kept.filter(entry => entry.type === "session_info").map(entry => entry.name),
    taken: taken && { ...taken, after: read(taken.file) },
    report: read(path.join(dir, "sessions", `${UNIT}.md`)),
    error: read(path.join(jobs, "error")),
    stopped: fs.existsSync(path.join(jobs, "stopped")),
    asked: fs.existsSync(path.join(jobs, "asked")),
    left: fs.readdirSync(path.join(jobs, "inbox")),
  };
  fs.rmSync(dir, { recursive: true, force: true });
  return ran;
}

const reported = text => `# ${UNIT} 试试\n\n${text}\n`;

function project({ seen, status, cwd, err, report }) {
  assert.equal(status, 0);
  assert.ok(seen.systems[0].includes(PROJECT), "the project's context file");
  assert.deepEqual(seen.calls[1], [`tool: ${cwd}\n`], "tools use the project's working directory");
  assert.equal(report, reported("项目完成"));
  assert.ok(!err.includes("untrusted extension loaded"), "project extensions stay untrusted");
}

const checks = {
  steers({ seen, status, report, left }) {
    assert.equal(status, 0);
    assert.deepEqual(seen.calls[1], ["tool: hi\n", "user: 先看 A\n", "user: 再看 B\n"]);
    assert.equal(report, reported("完成"));
    assert.deepEqual(left, [], "the steers are taken from the inbox");
    assert.ok(seen.systems[0].includes(`[笔记]\n${NOTES}`), "the notes for the directory");
  },
  last({ seen, report }) {
    // A steer taken at the last turn's end: pi goes on.
    assert.deepEqual(seen.calls[1], ["user: 再补一句\n"]);
    assert.equal(report, reported("定稿"));
  },
  stop({ seen, status, report, stopped, error }) {
    // Quick, too: sleep 30 was aborted.
    assert.equal(seen.calls.length, 1);
    assert.equal(report, reported("开始查"), "what it had written is its report");
    assert.ok(stopped, "it says it was told to stop");
    assert.equal(error, null, "being stopped is no failure of the model's");
    assert.notEqual(status, 0);
  },
  settle({ seen, status, report, asked }) {
    // Held about to settle, it went on with what came, then settled.
    assert.equal(status, 0);
    assert.deepEqual(seen.calls[1], [`user: ${ANSWER}\n`]);
    assert.equal(report, reported("订了火锅"));
    assert.ok(!asked, "it waits for nothing any more");
  },
  answered({ seen, status, report, asked, took }) {
    // The answer came while it worked: done, it waits for nothing.
    assert.equal(status, 0);
    assert.deepEqual(seen.calls[1], ["tool: hi\n", `user: ${ANSWER}\n`]);
    assert.equal(report, reported("订了火锅"));
    assert.ok(!asked, "it waits for nothing any more");
    assert.ok(took < HOLD, `it settled at once, not after ${took} ms`);
  },
  agents: project,
  claude: project,
  resume({ seen, status, report, header, taken }) {
    assert.equal(status, 0);
    // All the earlier said and did, then the task.
    assert.deepEqual(seen.whole[0], [`user: ${EARLIER.task}`, "assistant: ", "tool: foo is 42\n", "assistant: foo 是 42", `user: ${TASK}`]);
    assert.equal(report, reported("bar 也查了"));
    assert.equal(header.parentSession, taken.file, "the session says whose it goes on from");
    assert.equal(taken.after, taken.kept, "the earlier session is as it was");
    // Its own system text, with the notes written since.
    assert.ok(seen.systems[0].includes(`[笔记]\n${NOTES}`), "the notes as they are now");
  },
};

(async () => {
  let failed = 0;
  for (const [scenario, check] of Object.entries(checks)) {
    const ran = await agent(scenario);
    try {
      assert.deepEqual(ran.seen.calls[0].slice(-1), [`user: ${TASK}`], "the task as written");
      const system = ran.seen.systems[0];
      const at = system.indexOf(SYSTEM);
      assert.ok(at > 0 && system.indexOf(SYSTEM, at + 1) < 0, "the agent's system text, once, after pi's");
      assert.ok(!system.includes("@WORKDIR@") && !system.includes("@NOTES"), "with its directory and notes filled in");
      assert.ok(system.includes(`你在 ${ran.cwd} 下干活`), "its directory");
      if (!["steers", "resume"].includes(scenario)) assert.ok(system.includes("[笔记]\n（还没有，这次新建。）"), "no notes yet");
      assert.ok(system.includes(PARENT), "parent context files load without project trust");
      assert.ok(!system.includes(UNTRUSTED), "project system prompts stay untrusted");
      assert.ok(!system.includes(SIBLING), "other projects' context files don't load");
      assert.deepEqual(ran.seen.strangers, [], "calls of anything but the model");
      assert.deepEqual(ran.sessions.map(name => name.replace(/^[^_]*_/, "")), [`${UNIT}.jsonl`], "one session, named after the unit");
      assert.equal(ran.titles.at(-1), "试试", "titled as Max titled the agent");
      const asked = [MODEL, EFFORT[scenario] ?? null];
      assert.deepEqual(ran.seen.asked, ran.seen.asked.map(() => asked), "the model by max's name for it, asked to think as told");
      // pi exits only once nothing is left to wait for: else this is 60
      // seconds and a kill.
      assert.ok(ran.took < 15_000, `took ${ran.took} ms`);
      check(ran);
      console.log(`ok   ${scenario} (${ran.took} ms)`);
    } catch (error) {
      failed += 1;
      console.log(`FAIL ${scenario}: ${error.message}`);
      const { seen, ...others } = ran;
      console.log(JSON.stringify({ seen, ...others }, null, 2));
    }
  }
  process.exitCode = failed ? 1 : 0;
})();
