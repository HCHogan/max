// The client of Max's MCP service that run_code's runner and the maxx
// command share: a call is one POST, the outcome {ok: true, value} or
// {ok: false, error: {code, message}}. Without a token it calls as a
// program Max keeps in the VM, outside any turn. See "The MCP channel" in
// docs/rust-rewrite.md. A background agent's harness asks Max with job();
// see "Decoupling from the harness" there.
"use strict";

const MCP = "http://127.0.0.1:7777/mcp";
const VERSION = "2026-07-28";
// A stream of the timeline with nothing on it this long, not even the
// heartbeat the host sends every 30 seconds, is opened again.
const QUIET = 90_000;
// How long to wait before opening it again, at first and at most.
const RETRY = 1_000;
const MOST_RETRY = 30_000;

class ToolError extends Error {
  constructor(tool, error) {
    super(`${tool}: ${error.message}（${error.code}）`);
    this.name = "ToolError";
    this.code = error.code;
  }
}

// A client for the run whose token it is, if any, at url.
function connect({ url = MCP, token }) {
  let nextId = 1;

  async function post(method, params, signal) {
    let reply;
    try {
      const response = await fetch(url, {
        method: "POST",
        signal,
        headers: {
          "content-type": "application/json",
          accept: "application/json, text/event-stream",
          "mcp-protocol-version": VERSION,
          "mcp-method": method,
          ...(params.name ? { "mcp-name": params.name } : {}),
          ...(token ? { authorization: `Bearer ${token}` } : {}),
        },
        body: JSON.stringify({
          jsonrpc: "2.0",
          id: nextId++,
          method,
          params: {
            ...params,
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
    return { ok: true, value: reply.result };
  }

  // One call of a tool, or of the runner's own max.image and max.file.
  async function request(tool, args, signal) {
    const outcome = await post("tools/call", { name: tool, arguments: args }, signal);
    if (!outcome.ok) return outcome;
    const { isError, structuredContent } = outcome.value;
    if (isError) return { ok: false, error: structuredContent };
    return { ok: true, value: structuredContent };
  }

  // The tools this run, or program, may call, with their schemas.
  async function list() {
    const outcome = await post("tools/list", {});
    return outcome.ok ? { ok: true, value: outcome.value.tools } : outcome;
  }

  return { request, list };
}

// What only a background job does, by its token; see "Decoupling from the
// harness" in docs/rust-rewrite.md. Each but stopped() gives an outcome, as
// a call does.
//   turn()          at the end of a turn: {steers, stop}, the steers Max
//                   sent since the last, and whether to stop now
//   ask(question)   waits until Max answers, as long as that takes: the
//                   answer, or null if none came
//   stopped(signal) waits until the host says stop, opening the stream
//                   again if it breaks or goes quiet: true then, false
//                   once the job is over or `signal` ends the wait
//   report({text, error})  once the agent has settled: ends the job
function job({ url = MCP, token }) {
  const headers = { "content-type": "application/json", authorization: `Bearer ${token}` };
  const at = path => new URL(path, url);

  // A POST; the answer's text.
  async function post(path, body, signal) {
    try {
      const response = await fetch(at(path), { method: "POST", signal, headers, body: JSON.stringify(body) });
      if (!response.ok) return { ok: false, error: { code: "refused", message: await refused(response) } };
      return { ok: true, value: await response.text() };
    } catch (error) {
      if (error.name === "AbortError") return { ok: false, error: { code: "cancelled", message: "撤回了" } };
      return { ok: false, error: { code: "unreachable", message: `连不上 Max 的 MCP 服务：${error.message}` } };
    }
  }

  // The first line with something on it: lines with nothing keep a wait
  // alive.
  const first = text => text.split("\n").find(line => line.trim() !== "");

  async function turn() {
    const outcome = await post("/job/turn", {});
    return outcome.ok ? { ok: true, value: JSON.parse(outcome.value) } : outcome;
  }

  async function ask(question, signal) {
    const outcome = await post("/job/ask", { question }, signal);
    if (!outcome.ok) return outcome;
    const line = first(outcome.value);
    if (line === undefined) return { ok: false, error: { code: "unreachable", message: "Max 的 MCP 服务没给答复就断了" } };
    return { ok: true, value: JSON.parse(line).answer ?? null };
  }

  async function stopped(signal) {
    let wait = RETRY;
    while (!signal?.aborted) {
      // A stream quiet for longer than its heartbeat is broken.
      const quiet = new AbortController();
      let timer;
      const listen = () => {
        clearTimeout(timer);
        timer = setTimeout(() => quiet.abort(), QUIET);
      };
      try {
        listen();
        const either = signal ? AbortSignal.any([signal, quiet.signal]) : quiet.signal;
        const response = await fetch(at("/job/stop"), { headers, signal: either });
        // Not a job's, or not any more.
        if (!response.ok && response.status < 500) return false;
        if (response.ok) {
          wait = RETRY;
          const decoder = new TextDecoder();
          for await (const chunk of response.body) {
            if (decoder.decode(chunk, { stream: true }).trim() !== "") return true;
            listen();
          }
        }
      } catch {
        // Broken, or quiet: opened again.
      } finally {
        clearTimeout(timer);
      }
      // pi exits only once nothing is left to wait for.
      await new Promise(resolve => {
        const timer = setTimeout(resolve, wait);
        signal?.addEventListener("abort", () => (clearTimeout(timer), resolve()), { once: true });
      });
      wait = Math.min(wait * 2, MOST_RETRY);
    }
    return false;
  }

  async function report({ text = null, error = null }) {
    const outcome = await post("/job/report", { text, error });
    return outcome.ok ? { ok: true, value: null } : outcome;
  }

  return { turn, ask, stopped, report };
}

// The group's rows after the one numbered `after`, or from now, as the
// host's /events sends them, an object each; `told` hears why a stream
// broke and when it opens again. A stream that ends or goes quiet is
// opened again after the last row, so this never ends. See "Resident
// programs" in docs/rust-rewrite.md.
async function* events({ url = new URL("/events", MCP).href, after, told = () => {} } = {}) {
  let last = after;
  let wait = RETRY;
  for (;;) {
    const quiet = new AbortController();
    let timer;
    const listen = () => {
      clearTimeout(timer);
      timer = setTimeout(() => quiet.abort(), QUIET);
    };
    let why;
    try {
      listen();
      const response = await fetch(last === undefined ? url : `${url}?after=${last}`, { signal: quiet.signal });
      if (!response.ok) throw new Error(await refused(response));
      const head = response.headers.get("max-head");
      if (last === undefined && head !== null) last = Number(head);
      wait = RETRY;
      const decoder = new TextDecoder();
      let read = "";
      for await (const chunk of response.body) {
        // The program may take its time with a row.
        clearTimeout(timer);
        read += decoder.decode(chunk, { stream: true });
        let end;
        while ((end = read.indexOf("\n")) >= 0) {
          const line = read.slice(0, end);
          read = read.slice(end + 1);
          if (line === "") continue;
          const row = JSON.parse(line);
          last = row.id;
          yield row;
        }
        listen();
      }
      why = "断了";
    } catch (error) {
      why = quiet.signal.aborted ? `${QUIET / 1000} 秒没有动静` : error.message;
    } finally {
      clearTimeout(timer);
    }
    told(why, wait);
    await new Promise(resolve => setTimeout(resolve, wait));
    wait = Math.min(wait * 2, MOST_RETRY);
  }
}

// Why the host refused a stream.
async function refused(response) {
  const text = await response.text();
  try {
    return JSON.parse(text).error.message;
  } catch {
    return `HTTP ${response.status}：${text}`;
  }
}

module.exports = { MCP, ToolError, connect, events, job };
