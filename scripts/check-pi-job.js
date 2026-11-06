// Runs a few jobs with pi, max-pi.sh and max-job.ts against a fake host,
// and checks that pi keeps the job's contract: steers taken at a turn's
// end go in before the next model call, a stop aborts a tool under way,
// ask_max's answer reaches the model, the task arrives as written, and
// the report goes out before pi exits. See scripts/check-pi-job.
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

// What the model says at call `n` of `scenario`: content, and a tool call.
const SCRIPT = {
  steers: n => (n === 1 ? { tool: ["bash", { command: "echo hi" }] } : { content: "完成" }),
  last: n => ({ content: n === 1 ? "初稿" : "定稿" }),
  stop: n => (n === 1 ? { content: "开始查", tool: ["bash", { command: "sleep 30" }] } : { content: "不该到这" }),
  ask: n => (n === 1 ? { tool: ["ask_max", { question: "选火锅还是烧烤？" }] } : { content: "订了火锅" }),
};
// What the turn's end `n` takes.
const STEERS = { steers: ["先看 A", "再看 B"], last: ["再补一句"] };

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
  const seen = { calls: [], turns: 0, asks: [], reports: [], stops: 0, strangers: [] };
  const server = http.createServer((req, res) => {
    let body = "";
    req.on("data", chunk => (body += chunk));
    req.on("end", () => {
      const ours = req.url.startsWith("/llm/") || req.url.startsWith("/job/");
      if (ours && req.headers.authorization !== "Bearer the-job-token") seen.strangers.push(req.url);
      if (req.url === "/llm/chat/completions") {
        const request = JSON.parse(body);
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
      if (req.url === "/job/ask") {
        seen.asks.push(JSON.parse(body).question);
        res.writeHead(200, { "content-type": "application/x-ndjson" });
        res.write("\n");
        return setTimeout(() => res.end('{"answer":"火锅"}\n'), 300);
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
  for (const sub of ["runtime", "sessions", "work"]) fs.mkdirSync(path.join(dir, sub));
  const wrapper = fs
    .readFileSync(path.join(repo, "nix/max-pi.sh"), "utf8")
    .replaceAll("127.0.0.1:7777", `127.0.0.1:${port}`)
    .replaceAll("/work/.max/jobs", path.join(dir, "sessions"));
  fs.writeFileSync(path.join(dir, "max-pi.sh"), wrapper);
  const line = JSON.stringify({
    contract: 1, token: "the-job-token", task: TASK, model: "m", api: "openai-completions",
    window: 100000, max_output: null, effort: null, system: "你是测试用的后台 agent。",
  });
  const started = Date.now();
  const child = spawn("bash", ["-euo", "pipefail", path.join(dir, "max-pi.sh")], {
    cwd: path.join(dir, "work"),
    env: {
      ...process.env,
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
  return { seen, status, out, err, took: Date.now() - started };
}

const checks = {
  steers({ seen, status }) {
    assert.equal(status, 0);
    assert.deepEqual(seen.calls[1], ["tool: hi\n", "user: 先看 A", "user: 再看 B"]);
    assert.deepEqual(seen.reports, [{ text: "完成", error: null }]);
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
  ask({ seen }) {
    assert.deepEqual(seen.asks, ["选火锅还是烧烤？"]);
    assert.deepEqual(seen.calls[1], ["tool: Max 答复：火锅"]);
    assert.deepEqual(seen.reports, [{ text: "订了火锅", error: null }]);
  },
};

(async () => {
  let failed = 0;
  for (const [scenario, check] of Object.entries(checks)) {
    const ran = await job(scenario);
    try {
      assert.deepEqual(ran.seen.calls[0].slice(-1), [`user: ${TASK}`], "the task as written");
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
