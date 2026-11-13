// The run_code runner. max runs it in a group's VM once per run, as
// `node /run/max/runner.js`; see "Running in the group VM" in
// docs/rust-rewrite.md.
//
// stdin is one JSON object: {code, args, tools}. code is an async
// function body; tools.<name>(args) calls one of Max's tools, the host's
// through its service or the guest's own, as maxx does on the command
// line (tools.js): tools.show() and tools.video() leave the model
// something to see after the result, and tools.events() is the chat's
// rows as they come. max.browser() and max.page() reach the VM's browser
// (browser.js). stdout gets the program's result and nothing else: its
// console and its own writes go to stderr. The exit status is 0 when the
// program returned, 1 when it threw.
"use strict";

const { format, inspect } = require("node:util");
const { browser, page, snapshot } = require("./browser.js");
const { MCP, ToolError } = require("./client.js");
const { LOCAL, open } = require("./tools.js");

const result = process.stdout.write.bind(process.stdout);
const log = text => process.stderr.write(text);
process.stdout.write = process.stderr.write.bind(process.stderr);
for (const level of ["log", "info", "warn", "error", "debug"]) {
  console[level] = (...values) => log(format(...values) + "\n");
}

async function main() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  // Tests point the runner at their own server, and their own /work.
  const url = input.mcp ?? MCP;
  const work = input.work ?? "/work";

  // Programs' own child processes, such as maxx, call where it does.
  process.env.MAXX_MCP = url;
  const { request, follow } = open({ url, work });

  // A call's promise, and what cancels it. Using one without await reads
  // a field of a Promise; say so instead of quietly giving undefined.
  const controllers = new WeakMap();
  const tracked = (promise, controller) => {
    const proxy = new Proxy(promise, {
      get(target, key) {
        if (key === "then" || key === "catch" || key === "finally") return target[key].bind(target);
        if (typeof key === "symbol") return target[key];
        throw new TypeError("a tool call returns a Promise: await it first, as in const r = await tools.name(args)");
      },
    });
    controllers.set(proxy, controller);
    return proxy;
  };
  const raw = (tool, args = {}) => {
    if (!args || typeof args !== "object" || Array.isArray(args)) throw new TypeError("a tool's arguments must be an object");
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

  // The host's tools, by the names it gave, and the guest's own. One
  // that isn't a call gives what it follows, to read with for await.
  const tools = Object.create(null);
  for (const name of input.tools) tools[name] = args => call(name, args);
  for (const tool of LOCAL) {
    tools[tool.name] = tool.stream ? (args = {}) => follow({ after: args?.after }) : args => call(tool.name, args);
  }
  const max = Object.freeze({ raw, cancel, race, browser, page, snapshot });
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
  if (!(error instanceof Error)) return `threw ${shown(error)}`;
  const [first, ...frames] = String(error.stack ?? error).split("\n");
  const own = frames.flatMap(line => {
    const at = /<anonymous>:(\d+):(\d+)\)$/.exec(line);
    return at ? [`    at the program's line ${at[1] - 2}, column ${at[2]}`] : [];
  });
  return [first, ...own].join("\n");
}

function exit(text, code) {
  result(text, () => process.stderr.write("", () => process.exit(code)));
}

main().then(value => exit(shown(value), 0), error => exit(failure(error), 1));
