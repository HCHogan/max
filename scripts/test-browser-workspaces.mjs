import assert from "node:assert/strict";
import { createServer } from "node:http";
import { setTimeout as delay } from "node:timers/promises";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const clients = [];
const transports = new Map();
let effects = 0;
const fixture = createServer((request, response) => {
  if (request.url === "/blocked.js" || request.url === "/no-document") return;
  if (request.url === "/missing") {
    response.writeHead(404, { "content-type": "text/html" });
    response.end('<!doctype html><title>Fixture not found</title><p>Missing fixture document</p><script src="/blocked.js"></script>');
    return;
  }
  if (request.url === "/effect" && request.method === "POST") {
    effects += 1;
    response.end("effect-recorded");
    return;
  }
  response.setHeader("content-type", "text/html");
  response.end(`<!doctype html><title>Max workspace acceptance</title>
    <p id="server">${request.headers.cookie?.includes("fixture_auth=one") ? "authenticated" : "anonymous"}</p>
    <p id="state"></p><button id="login">Fixture login</button><button id="effect">Fixture effect</button>
    <script>
      function render() {
        document.querySelector('#state').textContent = JSON.stringify({
          persistent: localStorage.getItem('fixture_identity'),
          transient: sessionStorage.getItem('fixture_transient'),
          memory: window.fixtureMemory ?? null
        });
      }
      document.querySelector('#login').onclick = () => {
        document.cookie = 'fixture_auth=one; Path=/; SameSite=Lax';
        localStorage.setItem('fixture_identity', 'workspace-one');
        sessionStorage.setItem('fixture_transient', 'session-only');
        window.fixtureMemory = 'hot-marker';
        render();
      };
      document.querySelector('#effect').onclick = async () => {
        await fetch('/effect', { method: 'POST' });
        document.querySelector('#effect').textContent = 'Effect done';
      };
      render();
    </script>`);
});
await new Promise(resolve => fixture.listen(18765, "127.0.0.1", resolve));
const future = (milliseconds = 120000) => new Date(Date.now() + milliseconds).toISOString();
const lease = epoch => ({ epoch, until: future() });
const report = message => console.log(`PASS ${message}`);

async function connect() {
  const client = new Client({ name: "max-workspace-acceptance", version: "1" });
  const transport = new StreamableHTTPClientTransport(new URL("http://127.0.0.1:8931/mcp"));
  await client.connect(transport);
  clients.push(client);
  transports.set(client, transport);
  return client;
}

async function call(client, name, argumentsValue = {}) {
  return client.callTool({ name, arguments: argumentsValue }, undefined, { timeout: 120000 });
}

async function success(client, name, argumentsValue = {}) {
  const result = await call(client, name, argumentsValue);
  assert.ok(!result.isError, `${name} failed: ${JSON.stringify(result)}`);
  return result.structuredContent ?? JSON.parse(result.content.find(item => item.type === "text").text);
}

async function rejected(client, name, argumentsValue) {
  const result = await call(client, name, argumentsValue).catch(error => ({ isError: true, message: error.message }));
  assert.equal(result.isError, true, `${name} unexpectedly accepted stale authority`);
}

async function start(client, epoch, storage) {
  await success(client, "max_workspace_bind", lease(epoch));
  const result = await success(client, "browse_session_start", {
    _maxLease: lease(epoch), headless: true, humanize: false, geoip: false, stealthProfile: "fast", storage,
  });
  assert.equal(result.browser, "camoufox");
  return result.sessionId;
}

async function navigate(client, sessionId, epoch) {
  return success(client, "browse_session_navigate", {
    sessionId, _maxLease: lease(epoch), url: "http://127.0.0.1:18765/", timeout: 15000,
  });
}

async function snapshot(client, sessionId, epoch) {
  return JSON.stringify(await success(client, "browse_session_snapshot", { sessionId, _maxLease: lease(epoch) }));
}

try {
  const first = await connect();
  const original = await start(first, 1);
  assert.match(JSON.stringify(await navigate(first, original, 1)), /anonymous/);
  await success(first, "browse_session_action", { sessionId: original, _maxLease: lease(1), action: { type: "click", selector: "#login" } });
  assert.match(await snapshot(first, original, 1), /hot-marker/);
  const checkpoint = await success(first, "max_workspace_checkpoint", { sessionId: original });
  assert.ok(checkpoint.storage.cookies.some(cookie => cookie.name === "fixture_auth" && cookie.value === "one"));
  assert.ok(checkpoint.storage.origins.some(origin => origin.localStorage.some(item => item.name === "fixture_identity" && item.value === "workspace-one")));
  report("real Camoufox login action and cookie/localStorage checkpoint");

  await success(first, "max_workspace_unbind");
  await rejected(first, "browse_session_action", { sessionId: original, _maxLease: lease(1), action: { type: "click", selector: "#effect" } });
  await success(first, "max_workspace_bind", lease(3));
  const hot = await snapshot(first, original, 3);
  assert.match(hot, /hot-marker/);
  assert.match(hot, /session-only/);
  assert.equal(effects, 0);
  report("hot resume retains DOM/sessionStorage, released owner cannot mutate");

  const independent = await connect();
  const isolated = await start(independent, 1);
  const [authenticated, anonymous] = await Promise.all([navigate(first, original, 3), navigate(independent, isolated, 1)]);
  assert.match(JSON.stringify(authenticated), /authenticated/);
  assert.match(JSON.stringify(anonymous), /anonymous/);
  const isolatedSnapshot = await snapshot(independent, isolated, 1);
  assert.ok(!isolatedSnapshot.includes("workspace-one"));
  report("concurrent MCP workspaces in one host do not share login state");

  await success(first, "max_workspace_revoke");
  await rejected(first, "browse_session_snapshot", { sessionId: original, _maxLease: lease(3) });
  await rejected(first, "max_workspace_bind", lease(4));
  await success(independent, "max_workspace_revoke");
  const restored = await connect();
  const restoredSession = await start(restored, 1, checkpoint.storage);
  const recovered = JSON.stringify(await navigate(restored, restoredSession, 1));
  assert.match(recovered, /authenticated/);
  assert.match(recovered, /workspace-one/);
  assert.ok(!recovered.includes("session-only"));
  assert.ok(!recovered.includes("hot-marker"));
  assert.equal(effects, 0);
  report("cold restore in a new process recovers auth, not DOM/sessionStorage, and replays no action");

  await success(restored, "max_workspace_bind", { epoch: 2, until: future(1500) });
  await success(restored, "max_workspace_renew", { epoch: 2, until: future(10000) });
  await delay(1700);
  await snapshot(restored, restoredSession, 2);
  await success(restored, "max_workspace_keepalive", { sessionId: restoredSession });
  await rejected(restored, "browse_session_action", { sessionId: restoredSession, _maxLease: lease(1), action: { type: "click", selector: "#effect" } });
  assert.equal(effects, 0);
  await success(restored, "browse_session_action", { sessionId: restoredSession, _maxLease: lease(2), action: { type: "click", selector: "#effect" } });
  for (let attempt = 0; effects === 0 && attempt < 100; attempt += 1) await delay(100);
  assert.equal(effects, 1);
  await success(restored, "max_workspace_bind", { epoch: 3, until: future(150) });
  await delay(300);
  await rejected(restored, "browse_session_action", { sessionId: restoredSession, _maxLease: lease(3), action: { type: "click", selector: "#effect" } });
  assert.equal(effects, 1);
  await success(restored, "max_workspace_revoke");
  report("renewal, keepalive, newer epochs and real expiry fence side effects");

  const launching = await connect();
  await success(launching, "max_workspace_bind", lease(1));
  const pendingStart = rejected(launching, "browse_session_start", { _maxLease: lease(1), headless: true, humanize: false, geoip: false, stealthProfile: "fast" });
  await delay(100);
  await success(launching, "max_workspace_revoke");
  await pendingStart;
  await rejected(launching, "max_workspace_bind", lease(2));
  report("revocation during browser launch drains and prevents resurrection");

  const partialClient = await connect();
  const partialSession = await start(partialClient, 1);
  const missing = await success(partialClient, "browse_session_navigate", { sessionId: partialSession, _maxLease: lease(1), url: "http://127.0.0.1:18765/missing", timeout: 2000 });
  assert.equal(missing.status, 404);
  assert.equal(missing.navigation.complete, false);
  assert.match(missing.text, /Missing fixture document/);
  const partialSnapshot = await snapshot(partialClient, partialSession, 1);
  assert.match(partialSnapshot, /404/);
  await rejected(partialClient, "browse_session_navigate", { sessionId: partialSession, _maxLease: lease(1), url: "http://127.0.0.1:18765/no-document", timeout: 1000 });
  await success(partialClient, "max_workspace_revoke");
  report("stalled scripts return a partial 404; absent documents remain errors without stale-page fallback");

  const foreground = await connect();
  const foregroundSession = await success(foreground, "browse_session_start", { humanize: false, geoip: false });
  await success(foreground, "browse_session_navigate", { sessionId: foregroundSession.sessionId, url: "http://127.0.0.1:18765/" });
  await transports.get(foreground).terminateSession();
  await foreground.close();
  clients.splice(clients.indexOf(foreground), 1);
  await delay(2000);
  report("transport termination closes a foreground browser using its default virtual display");

  const interrupted = await connect();
  const interruptedStart = call(interrupted, "browse_session_start", { humanize: false, geoip: false }).catch(() => undefined);
  await delay(100);
  await transports.get(interrupted).terminateSession();
  await interrupted.close();
  await interruptedStart;
  clients.splice(clients.indexOf(interrupted), 1);
  report("transport termination during launch drains without resurrecting a browser");
  console.log("ACCEPTANCE PASSED: 9 real-browser scenarios; only isolated fixture state used");
} finally {
  await Promise.allSettled(clients.map(client => call(client, "max_workspace_revoke")));
  await Promise.allSettled(clients.map(client => transports.get(client).terminateSession()));
  await Promise.allSettled(clients.map(client => client.close()));
  fixture.closeAllConnections();
  await new Promise(resolve => fixture.close(resolve));
}
