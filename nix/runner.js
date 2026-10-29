// The run_code runner. max runs it in a group's VM once per run, as
// `node /run/max/runner.js`; see "在群 VM 里跑" in docs/rust-rewrite.md.
//
// stdin is one JSON object: {code, args, token, tools}. code is an async
// function body; tools.<name>(args) calls one of Max's tools through the
// MCP service with the run's token. stdout gets the program's result and
// nothing else: its console and its own writes go to stderr. The exit
// status is 0 when the program returned, 1 when it threw.
"use strict";

const { format, inspect } = require("node:util");

const MCP = "http://127.0.0.1:7777/mcp";
const VERSION = "2026-07-28";

const result = process.stdout.write.bind(process.stdout);
const log = text => process.stderr.write(text);
process.stdout.write = process.stderr.write.bind(process.stderr);
for (const level of ["log", "info", "warn", "error", "debug"]) {
  console[level] = (...values) => log(format(...values) + "\n");
}

class ToolError extends Error {
  constructor(tool, error) {
    super(`${tool}: ${error.message}（${error.code}）`);
    this.name = "ToolError";
    this.code = error.code;
  }
}

async function main() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  // Tests point the runner at their own server.
  const url = input.mcp ?? MCP;

  let nextId = 1;
  // The outcome of one call: {ok: true, value} or {ok: false, error}.
  async function request(tool, args, signal) {
    let reply;
    try {
      const response = await fetch(url, {
        method: "POST",
        signal,
        headers: {
          "content-type": "application/json",
          accept: "application/json, text/event-stream",
          "mcp-protocol-version": VERSION,
          "mcp-method": "tools/call",
          "mcp-name": tool,
          authorization: `Bearer ${input.token}`,
        },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: nextId++,
          method: "tools/call",
          params: {
            name: tool,
            arguments: args,
            _meta: {
              "io.modelcontextprotocol/protocolVersion": VERSION,
              "io.modelcontextprotocol/clientCapabilities": {},
            },
          },
        }),
      });
      reply = JSON.parse(await response.text());
    } catch (error) {
      // As the host says when it cancels a call.
      if (error.name === "AbortError") return { ok: false, error: { code: "cancelled", message: "调用取消了；会动群的操作可能已经生效，先看记录再决定要不要再来" } };
      return { ok: false, error: { code: "unreachable", message: `连不上 Max 的 MCP 服务：${error.message}` } };
    }
    if (reply.error) return { ok: false, error: { code: "refused", message: reply.error.message } };
    const { isError, structuredContent } = reply.result;
    if (isError) return { ok: false, error: structuredContent };
    return { ok: true, value: structuredContent };
  }

  // A call's promise, and what cancels it. Using one without await reads
  // a field of a Promise; say so instead of quietly giving undefined.
  const controllers = new WeakMap();
  const tracked = (promise, controller) => {
    const proxy = new Proxy(promise, {
      get(target, key) {
        if (key === "then" || key === "catch" || key === "finally") return target[key].bind(target);
        if (typeof key === "symbol") return target[key];
        throw new TypeError("工具调用返回的是 Promise，先 await：const r = await tools.名字(args)");
      },
    });
    controllers.set(proxy, controller);
    return proxy;
  };
  const raw = (tool, args = {}) => {
    if (!args || typeof args !== "object" || Array.isArray(args)) throw new TypeError("工具的参数要是一个对象");
    const controller = new AbortController();
    return tracked(request(tool, args, controller.signal), controller);
  };
  const call = (tool, args) => {
    const outcome = raw(tool, args);
    const value = outcome.then(outcome => {
      if (outcome.ok) return outcome.value;
      throw new ToolError(tool, outcome.error);
    });
    return tracked(value, controllers.get(outcome));
  };
  const cancel = promise => controllers.get(promise)?.abort();
  // The first call to settle; the others are cancelled.
  const race = promises => {
    const list = Array.from(promises);
    const others = index => list.forEach((promise, i) => i !== index && cancel(promise));
    return Promise.race(list.map((promise, index) => promise.then(
      value => { others(index); return value; },
      error => { others(index); throw error; },
    )));
  };

  const tools = Object.create(null);
  for (const name of input.tools) tools[name] = args => call(name, args);
  const max = Object.freeze({ raw, cancel, race });
  const AsyncFunction = (async () => {}).constructor;
  const program = new AsyncFunction("tools", "max", "args", input.code);
  return program(Object.freeze(tools), max, input.args);
}

function shown(value) {
  if (value === undefined) return "";
  if (typeof value === "string") return value;
  try {
    const json = JSON.stringify(value);
    if (json !== undefined) return json;
  } catch {}
  return inspect(value, { depth: 6 });
}

// The error and the program's own frames, by its own line numbers: the
// function's header takes two lines.
function failure(error) {
  if (!(error instanceof Error)) return `抛出了 ${shown(error)}`;
  const [first, ...frames] = String(error.stack ?? error).split("\n");
  const own = frames.flatMap(line => {
    const at = /<anonymous>:(\d+):(\d+)\)$/.exec(line);
    return at ? [`    at 程序第 ${at[1] - 2} 行第 ${at[2]} 列`] : [];
  });
  return [first, ...own].join("\n");
}

function exit(text, code) {
  result(text, () => process.stderr.write("", () => process.exit(code)));
}

main().then(value => exit(shown(value), 0), error => exit(failure(error), 1));
