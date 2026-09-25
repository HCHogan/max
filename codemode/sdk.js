// Host appends this factory's immutable catalog argument and the program body.
((bridge, names) => {
  "use strict";
  const parse = JSON.parse;
  const stringify = JSON.stringify;
  const allowed = new Set(names);
  delete globalThis.__maxCall;
  // No ambient clock or entropy. Use an authorized tool if the task needs them.
  globalThis.Date = undefined;
  Math.random = undefined;

  function exchange(request) {
    let response = parse(bridge(stringify(request)));
    if (response.result_ref) {
      const chunks = [];
      let offset = 0;
      for (;;) {
        const part = parse(bridge(stringify({result_ref: response.result_ref, offset})));
        if (part.bridge_error) throw new Error(part.bridge_error);
        chunks.push(part.chunk);
        if (part.done) break;
        if (!(part.next > offset)) throw new Error("invalid result continuation");
        offset = part.next;
      }
      response = parse(chunks.join(""));
    }
    if (response.bridge_error) throw new Error(response.bridge_error);
    return response;
  }

  function request(tool, args) {
    if (!allowed.has(tool)) throw new TypeError("tool is not in this round's catalog: " + tool);
    if (!args || typeof args !== "object" || Array.isArray(args))
      throw new TypeError("tool arguments must be an object");
    return {tool, args};
  }

  // Calls queue as pending promises. When no job can run, the guest's event
  // loop calls flush, which submits every queued call as one host batch (the
  // host runs it concurrently where tool metadata allows) and resolves them.
  // So calls started together, e.g. under Promise.all, run together.
  const queue = [];
  const flush = () => {
    if (!queue.length) return false;
    const pending = queue.splice(0, 32);
    let replies;
    try {
      replies = pending.length === 1 ? [exchange(pending[0].request)] : exchange({calls: pending.map(entry => entry.request)});
    } catch (error) {
      for (const entry of pending) entry.reject(error);
      return true;
    }
    pending.forEach((entry, index) => entry.resolve(replies[index]));
    return true;
  };
  Object.defineProperty(globalThis, "__maxFlush", {value: flush});

  // A tool result used without await is a Promise; say so instead of
  // letting a field read quietly produce undefined.
  const awaitable = promise =>
    new Proxy(promise, {
      get(target, key) {
        if (key === "then" || key === "catch" || key === "finally") return target[key].bind(target);
        throw new TypeError("tool calls return a Promise; await the result first (const r = await tools.name(args))");
      }
    });

  function value(outcome) {
    if (outcome.outcome === "succeeded" || outcome.outcome === "committed") return outcome.value;
    const error = new Error(outcome.error.message);
    error.name = "ToolError";
    error.outcome = outcome.outcome;
    error.code = outcome.error.code;
    error.retry = outcome.error.retry;
    throw error;
  }

  const submit = call => new Promise((resolve, reject) => queue.push({request: call, resolve, reject}));
  const raw = (tool, args = {}) => awaitable(submit(request(tool, args)));
  const call = (tool, args = {}) => awaitable(submit(request(tool, args)).then(value));
  // agent() is the agent tool waiting for its report; phase() is agent_progress.
  const agentArgs = args => {
    if (!args || typeof args !== "object" || Array.isArray(args)) throw new TypeError("agent arguments must be an object");
    return {...args, wait: true};
  };
  const agent = args => call("agent", agentArgs(args));
  const phase = summary => {
    if (typeof summary !== "string") throw new TypeError("phase requires a string");
    return call("agent_progress", {summary});
  };
  const tools = Object.create(null);
  for (const name of names) tools[name] = (args = {}) => call(name, args);
  // Kept for existing programs: the same as Promise.all over max.raw.
  const batch = calls => {
    if (!Array.isArray(calls) || calls.length < 1 || calls.length > 32)
      throw new RangeError("batch requires 1 to 32 calls");
    const requests = calls.map(entry => (entry.agent ? request("agent", agentArgs(entry.agent)) : request(entry.tool, entry.args ?? {})));
    return awaitable(Promise.all(requests.map(submit)));
  };
  Object.defineProperties(globalThis, {
    tools: {value: Object.freeze(tools)},
    agent: {value: agent},
    max: {value: Object.freeze({raw, batch, value, agent, phase, names: Object.freeze(names)})}
  });
})
