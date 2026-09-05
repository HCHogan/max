import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const moduleUrl = pathToFileURL(process.argv[2]);
const { navigatePage } = await import(moduleUrl.href);
const { errors } = createRequire(moduleUrl)("playwright-core");
const target = "https://example.test/missing";
const response = { url: () => target, status: () => 404 };
let navigations = 0;
const page = {
  goto: async (url, options) => {
    navigations += 1;
    assert.equal(url, target);
    assert.equal(options.waitUntil, "commit");
    return response;
  },
  waitForLoadState: async () => { throw new errors.TimeoutError("fixture readiness timeout"); },
  isClosed: () => false,
  url: () => target,
};
const partial = await navigatePage(page, target, "domcontentloaded", 2000);
assert.equal(partial.response.status(), 404);
assert.equal(partial.navigation.complete, false);
assert.equal(navigations, 1);
await assert.rejects(navigatePage({ ...page, goto: async () => { throw new errors.TimeoutError("no document"); } }, target, "domcontentloaded", 2000));
await assert.rejects(navigatePage({ ...page, url: () => "https://example.test/other" }, target, "domcontentloaded", 2000));
await assert.rejects(navigatePage({ ...page, isClosed: () => true }, target, "domcontentloaded", 2000));
await assert.rejects(navigatePage({ ...page, waitForLoadState: async () => { throw new Error("browser disconnected"); } }, target, "domcontentloaded", 2000));
assert.equal((await navigatePage({ ...page, waitForLoadState: async () => {} }, target, "domcontentloaded", 2000)).navigation.complete, true);
console.log("PASS navigation readiness failures preserve the committed response without replay or stale-page fallback");
