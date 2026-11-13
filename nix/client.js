// The client of max's service that run_code's runner and the maxx command
// share (tools.js): the host's tools, over HTTP. A call is one POST to
// /tools/<name> with its arguments as a JSON object, and its outcome is
// what comes back: {ok: true, value} or {ok: false, error: {code,
// message}}; GET /tools lists them, with their schemas. A call is the
// VM's: nothing says which program made it. See "The guest's calls" in
// docs/rust-rewrite.md.
"use strict";

// Where max is, for everything in the guest (guest.nix's max-host).
const MAX = "http://127.0.0.1:7777";
// A stream of the timeline with nothing on it this long, not even the
// heartbeat the host sends every 30 seconds, is opened again.
const QUIET = 90_000;
// How long to wait before opening it again, at first and at most.
const RETRY = 1_000;
const MOST_RETRY = 30_000;
// While max restarts, the guest's forwarder answers for it: 503 with
// max-away, and nothing of the request read (guest.nix's max-host@). A
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

// A client of max at url.
function connect({ url = MAX } = {}) {
  // What max answers a request with, as {ok: true, value}; asked again
  // while max is away, and a failure when it can't be reached or what
  // comes back isn't JSON.
  async function ask(method, path, body, signal) {
    const cancelled = { ok: false, error: { code: "cancelled", message: "the call was cancelled; what acts in the chat may have taken effect: look at the records before trying again" } };
    const asked = Date.now();
    let wait = RETRY;
    for (;;) {
      const outcome = await once(method, path, body, signal);
      if (outcome !== away) return outcome === aborted ? cancelled : outcome;
      if (Date.now() - asked + wait > AWAY) {
        return { ok: false, error: { code: "unreachable", message: `can't reach max: it has been away for ${Math.round((Date.now() - asked) / 1000)} seconds` } };
      }
      await sleep(wait, signal);
      if (signal?.aborted) return cancelled;
      wait = Math.min(wait * 2, MOST_RETRY);
    }
  }

  // One try: the answer, or `away` when max isn't there to take it.
  async function once(method, path, body, signal) {
    try {
      const response = await fetch(new URL(path, url), {
        method,
        signal,
        ...(body === undefined ? {} : { headers: { "content-type": "application/json" }, body: JSON.stringify(body) }),
      });
      if (response.status === 503 && response.headers.get("max-away")) return away;
      const text = await response.text();
      try {
        return { ok: true, value: JSON.parse(text) };
      } catch {
        return { ok: false, error: { code: "refused", message: `max answered ${response.status}: ${text.slice(0, 200)}` } };
      }
    } catch (error) {
      // As the host says when it cancels a call.
      if (error.name === "AbortError") return aborted;
      return { ok: false, error: { code: "unreachable", message: `can't reach max: ${error.message}` } };
    }
  }

  // One call of a tool: its outcome is max's answer.
  async function request(tool, args, signal) {
    const answer = await ask("POST", `/tools/${encodeURIComponent(tool)}`, args, signal);
    if (!answer.ok) return answer;
    const outcome = answer.value;
    if (outcome?.ok === true) return { ok: true, value: outcome.value };
    if (outcome?.ok === false && outcome.error) return { ok: false, error: outcome.error };
    return { ok: false, error: { code: "refused", message: `max answered ${JSON.stringify(outcome).slice(0, 200)}` } };
  }

  // The host's tools, with their schemas.
  async function list() {
    const answer = await ask("GET", "/tools");
    if (!answer.ok) return answer;
    if (Array.isArray(answer.value?.tools)) return { ok: true, value: answer.value.tools };
    return { ok: false, error: { code: "refused", message: `max answered ${JSON.stringify(answer.value).slice(0, 200)}` } };
  }

  return { request, list };
}

// The group's rows after the one numbered `after`, or from now, as the
// host's /events sends them, an object each; `told` hears why a stream
// broke and when it opens again. A stream that ends or goes quiet is
// opened again after the last row, so this never ends. See "Resident
// programs" in docs/rust-rewrite.md.
async function* events({ url = new URL("/events", MAX).href, after, told = () => {} } = {}) {
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

module.exports = { MAX, ToolError, connect, events };
