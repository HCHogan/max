// The client of Max's MCP service that run_code's runner and the maxx
// command share: a call is one POST, the outcome {ok: true, value} or
// {ok: false, error: {code, message}}. Without a token it calls as a
// program Max keeps in the VM, outside any turn. See "MCP 通道" in
// docs/rust-rewrite.md.
"use strict";

const MCP = "http://127.0.0.1:7777/mcp";
const VERSION = "2026-07-28";

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

module.exports = { MCP, ToolError, connect };
