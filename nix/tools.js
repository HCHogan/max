// Max's tools, for whatever calls them in a group's VM: the runner's
// tools.<name>(args), maxx on the command line and a program's own
// require of this file are all this, so none has a tool another lacks. A tool is the host's, called
// through its service (client.js), or the guest's own, in local.json:
// one the guest's systemd does, which `maxx <words> <json>` runs, or one
// of Node's own here, which leaves the model something to see (shown.js,
// video.js). Nothing here is about one tool but those last. See "maxx"
// in docs/rust-rewrite.md.
"use strict";

const { spawn } = require("node:child_process");
const { MAX, ToolError, connect, events } = require("./client.js");
const { failed, image } = require("./shown.js");
const { watch } = require("./video.js");
// The guest's own, as the command line and the system prompt read them
// too: {name, words, run, turn, description, guide, inputSchema,
// outputSchema}, and stream for one that isn't a call.
const LOCAL = require("./local.json");

const local = new Map(LOCAL.map(tool => [tool.name, tool]));

// What Node does itself, each with its outcome as a call's.
const OWN = {
  // A picture's bytes take the place of the arguments, in a program.
  show: (work, args) => {
    const src = args instanceof Uint8Array ? args : args.path;
    if (typeof src !== "string" && !(src instanceof Uint8Array)) {
      return failed("bad_arguments", "show takes {path}, a picture under /work, or a picture's bytes");
    }
    return image(work, src);
  },
  video: (work, { path, start, end }) => {
    if (typeof path !== "string") return failed("bad_arguments", "video takes {path}, such as /work/chat/a.mp4, with start and end");
    return watch(work, path, { start, end });
  },
};

// One of the guest's commands: maxx with its words and its arguments as
// JSON, which is how the host asks for it too. Its outcome is what it
// printed, or why it failed. It has this process for its caller: its
// input stays open for as long as the call is wanted, and no longer.
function command(tool, args, signal) {
  return new Promise(resolve => {
    const cancelled = { ok: false, error: { code: "cancelled", message: "the call was cancelled; what it started may run on" } };
    if (signal?.aborted) return resolve(cancelled);
    let child;
    try {
      child = spawn(process.env.MAXX_COMMAND ?? "maxx", [...tool.words, JSON.stringify(args)], { stdio: ["pipe", "pipe", "pipe"] });
    } catch (error) {
      return resolve(failed("unreachable", `maxx didn't start: ${error.message}`));
    }
    const out = [];
    const err = [];
    child.stdout.on("data", chunk => out.push(chunk));
    child.stderr.on("data", chunk => err.push(chunk));
    child.stdin.on("error", () => {});
    const gone = () => {
      child.stdin.destroy();
      resolve(cancelled);
    };
    signal?.addEventListener("abort", gone, { once: true });
    child.on("error", error => resolve(failed("unreachable", `maxx didn't start: ${error.message}`)));
    child.on("close", status => {
      signal?.removeEventListener("abort", gone);
      const said = Buffer.concat(out).toString("utf8");
      const why = Buffer.concat(err).toString("utf8").trim();
      if (status !== 0) {
        // 2 is a command line's own: what it was given is wrong.
        return resolve(failed(status === 2 ? "bad_arguments" : "failed", why || `it ended with status ${status}`));
      }
      try {
        // The last line: a login shell's own writes come before it.
        resolve({ ok: true, value: JSON.parse(said.trimEnd().split("\n").pop() || "null") });
      } catch {
        resolve(failed("failed", `it didn't say how it went: ${said.slice(0, 300)}`));
      }
    });
  });
}

// Max's tools at url, with /work at work: request(name, args, signal)
// calls one, the guest's own or the host's, and its outcome is {ok:
// true, value} or {ok: false, error: {code, message}}; list() is all of
// them with their schemas, the host's first; follow(args) is the chat's
// rows as they come.
function open({ url = MAX, work = "/work" } = {}) {
  const client = connect({ url });

  async function request(name, args, signal) {
    const tool = local.get(name);
    if (!tool) return client.request(name, args, signal);
    if (tool.stream) return failed("bad_arguments", `${name} isn't a call: it gives the rows as they come, for await (const row of tools.${name}(args))`);
    if (tool.run === "node") return OWN[name](work, args);
    return command(tool, args, signal);
  }

  async function list() {
    const outcome = await client.list();
    return outcome.ok ? { ok: true, value: [...outcome.value, ...LOCAL] } : outcome;
  }

  const follow = ({ after, told } = {}) => events({ url: new URL("/events", url).href, after, told });

  return { request, list, follow };
}

// For a program of Max's own in JS that isn't run_code's, as a unit's
// is: const { tools } = require("/run/max/tools.js"). tools.<name>(args)
// is what it is in run_code, the call's value or a ToolError thrown, and
// tools.events(args) the rows as they come.
let ready;
function program() {
  if (ready) return ready;
  const { request, follow } = open({ url: process.env.MAXX_URL, work: process.env.MAXX_WORK });
  ready = new Proxy(Object.create(null), {
    get(_, name) {
      // No promise itself, whatever awaits it.
      if (typeof name !== "string" || name === "then") return undefined;
      if (local.get(name)?.stream) return (args = {}) => follow({ after: args?.after });
      return async (args = {}) => {
        const outcome = await request(name, args);
        if (outcome.ok) return outcome.value;
        throw new ToolError(name, outcome.error);
      };
    },
  });
  return ready;
}

module.exports = {
  LOCAL,
  ToolError,
  local,
  open,
  get tools() {
    return program();
  },
};
