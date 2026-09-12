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

  function value(outcome) {
    if (outcome.outcome === "succeeded" || outcome.outcome === "committed") return outcome.value;
    const error = new Error(outcome.error.message);
    error.name = "ToolError";
    error.outcome = outcome.outcome;
    error.code = outcome.error.code;
    error.retry = outcome.error.retry;
    throw error;
  }

  const raw = (tool, args = {}) => exchange(request(tool, args));
  const agentRequest = args => {
    if (!allowed.has("task_start")) throw new TypeError("agent requires task_start in the workflow catalog");
    if (!args || typeof args !== "object" || Array.isArray(args)) throw new TypeError("agent arguments must be an object");
    return {agent: args};
  };
  const agent = args => value(exchange(agentRequest(args)));
  const phase = summary => {
    if (!allowed.has("task_progress")) throw new TypeError("phase requires task_progress in the workflow catalog");
    if (typeof summary !== "string") throw new TypeError("phase requires a string");
    return value(exchange({phase: summary}));
  };
  const tools = Object.create(null);
  for (const name of names) tools[name] = (args = {}) => value(raw(name, args));
  const batch = calls => {
    if (!Array.isArray(calls) || calls.length < 1 || calls.length > 32)
      throw new RangeError("batch requires 1 to 32 calls");
    return exchange({calls: calls.map(call => call.agent ? agentRequest(call.agent) : request(call.tool, call.args ?? {}))});
  };
  Object.defineProperties(globalThis, {
    tools: {value: Object.freeze(tools)},
    agent: {value: agent},
    max: {value: Object.freeze({raw, batch, value, agent, phase, names: Object.freeze(names)})}
  });
})
