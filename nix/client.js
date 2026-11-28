// The client of max's service that run_code's runner and the maxx command
// share (tools.js): the host's tools, over HTTP. A call is one POST to
// /tools/<name> with its arguments as a JSON object, and its outcome is
// what comes back: {ok: true, value} or {ok: false, error: {code,
// message}}; GET /tools lists them, with their schemas. A call is the
// VM's: nothing says which program made it. See "The guest's calls" in
// docs/design/tools.md.
"use strict";

// Where max is, for everything in the guest (guest.nix's max-host).
const MAX = "http://127.0.0.1:7777";
// A stream of the timeline with nothing on it this long, not even the
// heartbeat the host sends every 30 seconds, is opened again.
const QUIET = 90_000;
// How long to wait before opening it again, at first and at most.
const RETRY = 1_000;
const MOST_RETRY = 30_000;

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

class ToolError extends Error {
  constructor(tool, error) {
    super(`${tool}: ${error.message} (${error.code})`);
    this.name = "ToolError";
    this.code = error.code;
  }
}

// A client of max at url.
function connect({ url = MAX } = {}) {
  // What max answers a request with, as {ok: true, value}; a failure
  // when nothing answers or what comes back isn't JSON. It is asked
  // once: while max restarts the request waits on the host, at max's
  // socket, and the max that comes answers it. The VM, and what runs in
  // it, outlives max.
  async function ask(method, path, body) {
    try {
      const response = await fetch(new URL(path, url), {
        method,
        ...(body === undefined ? {} : { headers: { "content-type": "application/json" }, body: JSON.stringify(body) }),
      });
      const text = await response.text();
      try {
        return { ok: true, value: JSON.parse(text) };
      } catch {
        return { ok: false, error: { code: "refused", message: `max answered ${response.status}: ${text.slice(0, 200)}` } };
      }
    } catch (error) {
      // Nothing listens for max, or max went with the call in its
      // hands: either way the connection only closes.
      return { ok: false, error: { code: "unreachable", message: `max didn't answer (${error.message}); if it had begun the call, what acts in the chat may have taken effect: look at the records before trying again` } };
    }
  }

  // One call of a tool: its outcome is max's answer.
  async function request(tool, args) {
    const answer = await ask("POST", `/tools/${encodeURIComponent(tool)}`, args);
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
// host's /events sends them, an object each, with the row as data too
// if `full`; `told` hears why a stream broke and when it opens again. A
// stream that ends or goes quiet is opened again after the last row, so
// this never ends. See "Following the chat" in docs/design/jobs.md.
async function* events({ url = new URL("/events", MAX).href, after, full = false, told = () => {} } = {}) {
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
      const query = [last === undefined ? [] : [`after=${last}`], full ? ["full=1"] : []].flat().join("&");
      const response = await fetch(query ? `${url}?${query}` : url, { signal: quiet.signal });
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
