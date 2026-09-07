import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { setTimeout as delay } from "node:timers/promises";

const gatewayPath = resolve(process.argv[2]);
const require = createRequire(gatewayPath);
const { Client } = require("@modelcontextprotocol/sdk/client/index.js");
const { StreamableHTTPClientTransport } = require("@modelcontextprotocol/sdk/client/streamableHttp.js");
const directory = await mkdtemp(`${tmpdir()}/max-gateway-disconnect-`);
const endpointFile = `${directory}/endpoint.json`;
const started = `${directory}/started`;
await mkdir(started);
const fixture = `${directory}/fixture.mjs`;
await writeFile(fixture, `
import { createInterface } from 'node:readline';
import { writeFileSync } from 'node:fs';
const reply = (request, result) => process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:request.id,result})+'\\n');
createInterface({input:process.stdin}).on('line', line => {
  const request = JSON.parse(line);
  if (request.method === 'initialize') {
    writeFileSync(${JSON.stringify(started)}+'/'+process.pid, 'received');
    setTimeout(() => reply(request, {
      protocolVersion:request.params.protocolVersion,
      capabilities:{tools:{}}, serverInfo:{name:'delayed-fixture',version:'1'}
    }), 500);
  } else if (request.method === 'tools/list') reply(request, {tools:[]});
});
`);
const quote = value => `'${value.replaceAll("'", "'\\''")}'`;
const gateway = spawn(process.execPath, [gatewayPath,
  "--logLevel", "none", "--stateful", "--outputTransport", "streamableHttp",
  "--streamableHttpPath", "/mcp", "--port", "0",
  "--stdio", `exec ${quote(process.execPath)} ${quote(fixture)}`,
], { detached: true, env: { ...process.env, MAX_BROWSER_ENDPOINT_FILE: endpointFile }, stdio: ["ignore", "ignore", "pipe"] });
let errors = "";
gateway.stderr.on("data", chunk => { errors += chunk.toString(); });
const exited = new Promise(resolveExit => gateway.once("exit", resolveExit));
const client = new Client({ name: "healthy-sibling", version: "1" });
let transport;
async function waitFor(action) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    assert.equal(gateway.exitCode, null, `gateway exited: ${errors}`);
    if (await action()) return;
    await delay(25);
  }
  throw new Error("timed out waiting for fixture");
}
try {
  let port;
  await waitFor(async () => {
    try { port = JSON.parse(await readFile(endpointFile, "utf8")).port; return true; }
    catch (error) { if (error.code === "ENOENT") return false; throw error; }
  });
  const endpoint = new URL(`http://127.0.0.1:${port}/mcp`);
  transport = new StreamableHTTPClientTransport(endpoint);
  await client.connect(transport, { timeout: 5000 });
  assert.deepEqual(await client.listTools({}, { timeout: 5000 }), { tools: [] });

  const abort = new AbortController();
  const abandoned = fetch(endpoint, {
    method: "POST", signal: abort.signal,
    headers: { "content-type": "application/json", accept: "application/json, text/event-stream" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {
      protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "disconnecting", version: "1" },
    } }),
  }).catch(error => error);
  // Wait for the child to receive the request, then close before its response.
  await waitFor(async () => (await readdir(started)).length === 2);
  abort.abort();
  await abandoned;
  await delay(800);
  assert.equal(gateway.exitCode, null, `a disconnected client killed its sibling: ${errors}`);
  assert.deepEqual(await client.listTools({}, { timeout: 5000 }), { tools: [] });
  console.log("PASS disconnected initialize cannot crash a healthy sibling MCP session");
} finally {
  await client.close().catch(() => {});
  try { process.kill(-gateway.pid, "SIGTERM"); } catch (error) { if (error.code !== "ESRCH") throw error; }
  await exited;
  await rm(directory, { recursive: true, force: true });
}
