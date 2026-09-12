// Run with the built package's node_modules visible beside this script.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { writeFile } from "node:fs/promises";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const origin = "http://127.0.0.1:18765";
const fixture = createServer((req, res) => {
  if (req.url === "/pending.js") return;
  res.setHeader("content-type", "text/html");
  if (req.url === "/slow") {
    res.end('<title>Partial document</title><p>Content arrived before readiness timeout</p><script src="/pending.js"></script>');
  } else if (req.url === "/private") {
    res.end('<title>Blocked</title><script src="http://192.168.254.254/private.js"></script>');
  } else if (req.url === "/frame") {
    res.end('<title>Frame</title><form id="form"><input id="input" name="input"><select id="select"><option value="a">A</option><option value="b">B</option></select></form>');
  } else if (req.url === "/lazy") {
    res.end(`<title>Lazy collection</title><div id="items"><p style="height:500px">Lazy block 0</p><p style="height:500px">Lazy block 1</p><p style="height:500px">Lazy block 2</p></div>
      <script>let n=3; addEventListener('scroll',()=>{ if(scrollY+innerHeight>=document.body.scrollHeight-250 && n<10) { const p=document.createElement('p');p.style.height='500px';p.textContent='Lazy block '+n++;document.querySelector('#items').append(p); } });</script>`);
  } else {
    res.end(`<title>Browser surface fixture</title><script src="https://tracker.invalid/analytics.js"></script>
      <article><h1 id="heading">Fixture article</h1><p>Article-only content.</p><a href="/frame">Frame link</a></article>
      <input id="input"><button id="click" onclick="this.textContent='Clicked'">Click me</button><iframe id="frame" src="/frame"></iframe>
      <button id="confirm" onclick="this.textContent=confirm('Confirm fixture?')?'Accepted':'Dismissed'">Confirm</button>
      ${Array.from({length: 800}, (_, i) => `<p>Article paragraph ${i}: reproducible browser content for bounded output.</p><button id="b${i}">Button ${i}</button>`).join("")}`);
  }
});
await new Promise(resolve => fixture.listen(18765, "127.0.0.1", resolve));
const transport = new StreamableHTTPClientTransport(new URL(process.env.MAX_BROWSER_ENDPOINT));
const client = new Client({ name: "max-browser-surface-acceptance", version: "1" });
const outputs = [];
const lease = { epoch: 1, until: new Date(Date.now() + 600000).toISOString() };
const call = (name, args) => client.callTool({ name, arguments: { ...args, _maxLease: lease } }, undefined, { timeout: 120000 });
const payload = result => result.structuredContent ?? JSON.parse(result.content.find(item => item.type === "text").text);
async function success(action, name, args) {
  const result = await call(name, args);
  assert.ok(!result.isError, `${name}: ${JSON.stringify(result)}`);
  outputs.push({ action, request: args, raw: result });
  return payload(result);
}
try {
  await client.connect(transport);
  await call("max_workspace_bind", lease);
  const started = await call("browse_session_start", { headless: true, geoip: false, humanize: false });
  assert.ok(!started.isError, JSON.stringify(started));
  const sessionId = payload(started).sessionId;
  const limits = { sessionId, maxChars: 6000, maxElements: 40 };
  const opened = await success("open", "browse_session_navigate", { ...limits, url: origin, timeout: 10000 });
  assert.match(opened.notes.join(), /tracker.invalid.*DNS/);
  assert.equal(opened.position.width, 1280);
  assert.equal(opened.position.height, 800);
  const snapshot = await success("snapshot", "browse_session_snapshot", limits);
  assert.ok(snapshot.elements.some(element => element.selector === "#click"));
  assert.equal(snapshot.notes.length, 0);
  const oldLimits = await success("snapshot", "browse_session_snapshot", { sessionId, maxChars: 30000, maxElements: 100 });
  console.log(`MEASURE identical page snapshot: inherited limits ${JSON.stringify(oldLimits).length} chars; explicit 6000/40 limits ${JSON.stringify(snapshot).length} chars before Haskell projection`);
  await success("click", "browse_session_action", { sessionId, maxChars: 1500, maxElements: 20, action: { type: "click", selector: "#click" } });
  const framed = await success("snapshot", "browse_session_snapshot", { ...limits, frame: "#frame" });
  assert.ok(framed.elements.some(element => element.selector === "#select"));
  await success("fill", "browse_session_action", { sessionId, maxChars: 1500, maxElements: 20, action: { type: "fill", selector: "#input", frame: "#frame", value: "typed in frame" } });
  await success("select", "browse_session_action", { sessionId, maxChars: 1500, maxElements: 20, action: { type: "select", selector: "#select", frame: "#frame", value: "b" } });
  const evaluated = await success("evaluate", "browse_session_action", { sessionId, maxChars: 1500, maxElements: 20, action: { type: "evaluate", frame: "#frame", expression: "document.querySelector('#input').value", maxChars: 1500 } });
  assert.match(JSON.stringify(evaluated.action.result), /typed in frame/);
  const partial = await success("open", "browse_session_navigate", { ...limits, url: origin + "/slow", timeout: 5000 });
  assert.equal(partial.navigation.complete, false);
  assert.match(partial.text, /Content arrived/);
  const rejected = await call("browse_session_navigate", { ...limits, url: origin + "/private", timeout: 5000 });
  assert.equal(rejected.isError, true);
  await success("open", "browse_session_navigate", { ...limits, url: origin, timeout: 10000 });
  console.log("PASS real Camoufox DNS note drains, private requests fail without poisoning later calls, timeout preserves partial document, frame snapshot/fill/select/evaluate work");
  if (process.env.MAX_BROWSER_EXTENDED !== "0") {
    const inspect = (action, extra = {}) => success(action, "browse_session_inspect", { ...limits, action, ...extra });
    assert.match((await inspect("read")).text, /Article-only content/);
    assert.match((await inspect("read", { mode: "outline" })).text, /#heading/);
    assert.match((await inspect("find", { query: "paragraph 20" })).text, /paragraph 20/);
    assert.match((await inspect("links")).text, /\/frame/);
    assert.match((await inspect("forms", { frame: "#frame" })).text, /#input/);
    const act = (type, extra) => success(type, "browse_session_action", { sessionId, maxChars: 1500, maxElements: 20, action: { type, ...extra } });
    await act("hover", { selector: "#click" });
    await act("type", { selector: "#input", text: "abc", delay: 10 });
    await act("press", { selector: "#input", key: "Tab" });
    await act("waitFor", { selector: "#click", state: "visible" });
    const dialog = await act("click", { selector: "#confirm" });
    assert.match(dialog.notes.join(), /dialog confirm auto-dismiss/);
    await inspect("dialog", { response: "accept" });
    const accepted = await act("click", { selector: "#confirm" });
    assert.match(accepted.notes.join(), /dialog confirm auto-accept/);
    const screenshot = await call("browse_session_inspect", { ...limits, action: "screenshot" });
    assert.ok(!screenshot.isError, JSON.stringify(screenshot));
    const image = screenshot.content.find(item => item.type === "image");
    assert.equal(image.mimeType, "image/jpeg");
    const bytes = Buffer.from(image.data, "base64");
    assert.ok(bytes.length <= 2000000);
    let dimensions;
    for (let i = 2; i < bytes.length - 8;) {
      assert.equal(bytes[i], 0xff);
      const marker = bytes[i + 1], size = bytes.readUInt16BE(i + 2);
      if ([0xc0, 0xc1, 0xc2].includes(marker)) { dimensions = [bytes.readUInt16BE(i + 7), bytes.readUInt16BE(i + 5)]; break; }
      i += 2 + size;
    }
    assert.deepEqual(dimensions, [1280, 800]);
    const collected = await inspect("collect", { maxChars: 6000, maxScrolls: 4, waitMs: 100 });
    assert.match(collected.text, /Article paragraph/);
    assert.ok(collected.text.length <= 6000);
    assert.match(collected.notes.join(), /collect stopped:/);
    await success("open", "browse_session_navigate", { ...limits, url: origin + "/lazy", timeout: 10000 });
    const lazy = await inspect("collect", { maxScrolls: 6, waitMs: 150 });
    assert.match(lazy.text, /Lazy block 3/);
    assert.equal(lazy.text.match(/Lazy block 0/g)?.length, 1);
    const foregroundTransport = new StreamableHTTPClientTransport(new URL(process.env.MAX_BROWSER_ENDPOINT));
    const foreground = new Client({ name: "foreground-policy-fixture", version: "1" });
    try {
      await foreground.connect(foregroundTransport);
      const start = await foreground.callTool({ name: "browse_session_start", arguments: { headless: true, geoip: false } });
      assert.ok(!start.isError);
      const result = await foreground.callTool({ name: "browse_session_action", arguments: {
        sessionId: payload(start).sessionId, action: { type: "evaluate", expression: "1+1" }, _maxLease: lease,
      } });
      assert.equal(result.isError, true);
      assert.match(result.content[0].text, /requires a task workspace/);
    } finally {
      await foreground.callTool({ name: "max_workspace_revoke", arguments: {} }).catch(() => {});
      await foreground.close().catch(() => {});
      await foregroundTransport.close().catch(() => {});
    }
    console.log("PASS session article/outline/find/links/forms, hover/type/press/wait, one-shot dialogs, 1280x800 screenshot and bounded collect");
  }
  await writeFile(process.env.MAX_BROWSER_MEASURE_FILE ?? "/tmp/max-browser-measure.json", JSON.stringify(outputs));
} finally {
  await call("max_workspace_revoke", {}).catch(() => {});
  await client.close().catch(() => {});
  await transport.close().catch(() => {});
  fixture.closeAllConnections();
  await new Promise(resolve => fixture.close(resolve));
}
