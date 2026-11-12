// The client of Max's MCP service that run_code's runner and the maxx
// command share: a call is one POST, the outcome {ok: true, value} or
// {ok: false, error: {code, message}}. A call is the VM's: nothing says
// which program made it. See "The MCP channel" in docs/rust-rewrite.md.
"use strict";

const MCP = "http://127.0.0.1:7777/mcp";
const VERSION = "2026-07-28";
// A stream of the timeline with nothing on it this long, not even the
// heartbeat the host sends every 30 seconds, is opened again.
const QUIET = 90_000;
// How long to wait before opening it again, at first and at most.
const RETRY = 1_000;
const MOST_RETRY = 30_000;
// While max restarts, the guest's forwarder answers for it: 503 with
// max-away, and nothing of the request read (guest.nix's max-mcp@). A
// call is made again, with those waits, until max is back or this long
// has passed. The VM, and what runs in it, outlives max.
const AWAY = 180_000;

// Waits ms, or until signal aborts, and leaves nothing behind: a listener
// left on a signal at every retry piled up.
function sleep(ms, signal) {
  return new Promise(resolve => {
    if (signal?.aborted) return resolve();
    const done = () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", done);
      resolve();
    };
    const timer = setTimeout(done, ms);
    signal?.addEventListener("abort", done, { once: true });
  });
}

// What one try of a call came to, besides an outcome.
const away = Symbol("away");
const aborted = Symbol("aborted");

class ToolError extends Error {
  constructor(tool, error) {
    super(`${tool}: ${error.message} (${error.code})`);
    this.name = "ToolError";
    this.code = error.code;
  }
}

// A client of the service at url.
function connect({ url = MCP } = {}) {
  let nextId = 1;

  async function post(method, params, signal) {
    const cancelled = { ok: false, error: { code: "cancelled", message: "the call was cancelled; what acts in the chat may have taken effect: look at the records before trying again" } };
    const asked = Date.now();
    let wait = RETRY;
    for (;;) {
      const outcome = await once(method, params, signal);
      if (outcome !== away) return outcome === aborted ? cancelled : outcome;
      if (Date.now() - asked + wait > AWAY) {
        return { ok: false, error: { code: "unreachable", message: `can't reach Max's MCP service: max has been away for ${Math.round((Date.now() - asked) / 1000)} seconds` } };
      }
      await sleep(wait, signal);
      if (signal?.aborted) return cancelled;
      wait = Math.min(wait * 2, MOST_RETRY);
    }
  }

  // One try: the outcome, or `away` when max isn't there to take it.
  async function once(method, params, signal) {
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
      if (response.status === 503 && response.headers.get("max-away")) return away;
      reply = JSON.parse(await response.text());
    } catch (error) {
      // As the host says when it cancels a call.
      if (error.name === "AbortError") return aborted;
      return { ok: false, error: { code: "unreachable", message: `can't reach Max's MCP service: ${error.message}` } };
    }
    if (reply.error) return { ok: false, error: { code: "refused", message: reply.error.message } };
    return { ok: true, value: reply.result };
  }

  // One call of a tool.
  async function request(tool, args, signal) {
    const outcome = await post("tools/call", { name: tool, arguments: args }, signal);
    if (!outcome.ok) return outcome;
    const { isError, structuredContent } = outcome.value;
    if (isError) return { ok: false, error: structuredContent };
    return { ok: true, value: structuredContent };
  }

  // Max's tools, with their schemas.
  async function list() {
    const outcome = await post("tools/list", {});
    return outcome.ok ? { ok: true, value: outcome.value.tools } : outcome;
  }

  return { request, list };
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
      why = "the connection dropped";
    } catch (error) {
      why = quiet.signal.aborted ? `nothing for ${QUIET / 1000} seconds` : error.message;
    } finally {
      clearTimeout(timer);
    }
    told(why, wait);
    await sleep(wait);
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

module.exports = { MCP, ToolError, connect, events };
