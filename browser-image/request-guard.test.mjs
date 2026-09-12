import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const { installRequestGuard } = await import(pathToFileURL(process.argv[2]));
let route, socket;
const guard = await installRequestGuard({
  on() {}, route: async (_, handler) => { route = handler; },
  routeWebSocket: async (_, handler) => { socket = handler; },
});
async function request(url) {
  let outcome;
  await route({ request: () => ({ url: () => url }),
    abort: async () => { outcome = "aborted"; },
    continue: async () => { outcome = "continued"; } });
  return outcome;
}
guard.beginOperation();
assert.equal(await request("https://tracker.invalid/tag?private=secret"), "aborted");
assert.doesNotThrow(() => guard.assertAllowed());
assert.match(guard.drainNotes().join(), /tracker.invalid.*DNS/);
assert.deepEqual(guard.drainNotes(), []);
assert.equal(await request("https://1.1.1.1/"), "continued");
guard.beginOperation();
for (let index = 0; index < 1030; index++) await request("https://1.1.1.1/");
assert.doesNotThrow(() => guard.assertAllowed());
assert.match(guard.drainNotes().join(), /budget exhausted/);
guard.beginOperation();
assert.equal(await request("https://1.1.1.1/"), "continued");
assert.equal(await request("http://192.168.1.1/private"), "aborted");
assert.throws(() => guard.assertAllowed(), /unsafe/);
guard.beginOperation();
assert.doesNotThrow(() => guard.assertAllowed());
let connected = false, closed = false;
await socket({ url: () => "ws://10.0.0.1/private", connectToServer: () => { connected = true; }, close: async () => { closed = true; } });
assert.equal(connected, false);
assert.equal(closed, true);
assert.throws(() => guard.assertAllowed(), /unsafe/);
assert.ok(!guard.drainNotes().join().includes("secret"));
console.log("PASS DNS abort is a drainable note; private HTTP/WebSocket targets fail; request budget and errors recover next operation");
