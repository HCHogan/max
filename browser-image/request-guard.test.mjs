import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const { installRequestGuard } = await import(pathToFileURL(process.argv[2]));
let route, socket;
const listeners = {};
const guard = await installRequestGuard({
  on(event, handler) { listeners[event] = handler; }, route: async (_, handler) => { route = handler; },
  routeWebSocket: async (_, handler) => { socket = handler; },
});
const mainFrame = { parentFrame: () => null };
const childFrame = { parentFrame: () => mainFrame };
function fakeRequest(url, { navigation = false, frame = mainFrame } = {}) {
  return { url: () => url, isNavigationRequest: () => navigation, frame: () => frame };
}
async function request(url, options) {
  let outcome;
  await route({ request: () => fakeRequest(url, options),
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
console.log("PASS DNS aborts and the request budget are drainable notes");

guard.beginOperation();
assert.equal(await request("https://1.1.1.1/"), "continued");
listeners.request(fakeRequest("http://192.168.1.1/pixel.png?private=secret"));
assert.equal(await request("http://192.168.1.1/pixel.png?private=secret"), "aborted");
assert.equal(await request("http://10.0.0.1/frame", { navigation: true, frame: childFrame }), "aborted");
assert.doesNotThrow(() => guard.assertAllowed());
let socketConnected = false, socketClosed = false;
await socket({ url: () => "ws://127.0.0.1:35729/livereload", connectToServer: () => { socketConnected = true; }, close: async () => { socketClosed = true; } });
assert.equal(socketConnected, false);
assert.equal(socketClosed, true);
assert.doesNotThrow(() => guard.assertAllowed());
const skipped = guard.drainNotes().join("\n");
assert.match(skipped, /192\.168\.1\.1: private, reserved or disallowed target; resource skipped/);
assert.match(skipped, /10\.0\.0\.1: .*resource skipped/);
assert.match(skipped, /127\.0\.0\.1: .*resource skipped/);
assert.ok(!skipped.includes("secret"));
console.log("PASS private subresources, frames and WebSockets are aborted and noted without failing the page");

guard.beginOperation();
assert.equal(await request("http://192.168.1.1/admin?private=secret", { navigation: true }), "aborted");
assert.throws(() => guard.assertAllowed(), error => /unsafe/.test(error.message) && /192\.168\.1\.1/.test(error.message) && !error.message.includes("secret"));
guard.beginOperation();
assert.doesNotThrow(() => guard.assertAllowed());
listeners.request(fakeRequest("http://localhost/", { navigation: true }));
assert.throws(() => guard.assertAllowed(), /host localhost/);
guard.beginOperation();
listeners.response({ url: () => "data:text/plain,ok" });
assert.doesNotThrow(() => guard.assertAllowed());
listeners.response({ url: () => "http://10.0.0.1/escaped" });
assert.throws(() => guard.assertAllowed(), /host 10\.0\.0\.1/);
guard.beginOperation();
assert.doesNotThrow(() => guard.assertAllowed());
console.log("PASS a private top-level document or an unrouted private response fails the operation and names only the host");
