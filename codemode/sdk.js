// Host appends this factory's immutable catalog argument and the program body.
((names) => {
  "use strict";
  const parse = JSON.parse;
  const stringify = JSON.stringify;
  const allowed = new Set(names);
  // No ambient clock or entropy. Use an authorized tool if the task needs them.
  globalThis.Date = undefined;
  Math.random = undefined;

  function request(tool, args) {
    if (!allowed.has(tool)) throw new TypeError("tool is not in this round's catalog: " + tool);
    if (!args || typeof args !== "object" || Array.isArray(args))
      throw new TypeError("tool arguments must be an object");
    return {tool, args};
  }

  // Promise reactions remain in the heap while the host runs calls. Taking
  // the outbox never waits for a tool and settling never invokes the host.
  let nextId = 1;
  const waiting = new Map();
  const outbox = [];
  const cancellations = [];
  const ids = new WeakMap();
  const take = () => ({calls: outbox.splice(0, Math.max(0, 64 -
    [...waiting.values()].filter(x => x.started).length)).map(call => {
      waiting.get(call.id).started = true;
      return call;
    }), cancel: cancellations.splice(0), waiting: waiting.size});
  const settle = outcomes => {
    for (const [id, outcome] of outcomes) {
      const entry = waiting.get(id);
      if (!entry || !entry.started) throw new Error("unexpected completion id");
      waiting.delete(id);
      entry.resolve(outcome);
    }
  };
  Object.defineProperties(globalThis, {
    __maxTake: {value: take}, __maxSettle: {value: settle}
  });

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

  const submit = call => {
    const id = nextId++;
    const promise = new Promise((resolve, reject) => waiting.set(id, {resolve, reject, started: false}));
    outbox.push({id, ...call});
    ids.set(promise, id);
    return promise;
  };
  const tracked = (promise, transform) => {
    const result = awaitable(transform ? promise.then(transform) : promise);
    ids.set(result, ids.get(promise));
    return result;
  };
  const raw = (tool, args = {}) => tracked(submit(request(tool, args)));
  const call = (tool, args = {}) => tracked(submit(request(tool, args)), value);
  const cancel = promise => {
    const id = ids.get(promise);
    if (id === undefined) throw new TypeError("cancel requires a direct tool promise");
    const entry = waiting.get(id);
    if (!entry) return;
    if (entry.started) {
      if (!entry.cancelled) cancellations.push(id);
      entry.cancelled = true;
    }
    else {
      outbox.splice(outbox.findIndex(x => x.id === id), 1);
      waiting.delete(id);
      entry.resolve({outcome: "rejected", error: {code: "cancelled", message: "call cancelled", retry: "safe"}});
    }
  };
  const race = promises => {
    const list = Array.from(promises);
    if (list.some(p => !ids.has(p))) throw new TypeError("race requires direct tool promises");
    return Promise.race(list.map((p, index) => Promise.resolve(p).then(
      result => { list.forEach((other, i) => {if (i !== index) cancel(other);}); return result; },
      error => { list.forEach((other, i) => {if (i !== index) cancel(other);}); throw error; }
    )));
  };
  const sleep = ms => {
    if (!Number.isSafeInteger(ms) || ms < 0 || ms > 21600000) throw new RangeError("sleep requires 0..21600000 milliseconds");
    return tracked(submit({tool: "$sleep", args: {ms}}), value);
  };
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
  const tell = (text, {urgent = false} = {}) => {
    if (typeof text !== "string" || typeof urgent !== "boolean") throw new TypeError("tell requires text and a boolean urgent flag");
    return call("agent_tell", {text, urgent});
  };
  const ask = question => {
    if (typeof question !== "string") throw new TypeError("ask requires a question string");
    return call("agent_ask", {question});
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
    max: {value: Object.freeze({raw, batch, value, agent, phase, tell, ask, race, cancel, sleep, names: Object.freeze(names)})}
  });
})
