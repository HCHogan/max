import assert from "node:assert/strict";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { test } from "node:test";

const runtime = await import(pathToFileURL(resolve(process.argv[2] ?? "dist/workspace-lease.js")).href);
const future = () => new Date(Date.now() + 60_000).toISOString();
const request = (epoch, action) => runtime.withWorkspaceLease("browse_session_action", { _maxLease: { epoch, until: future() } }, action);

test("workspace lease fences admission, queued work, release and revocation", async () => {
  runtime.bindWorkspaceLease({ epoch: 1, until: future() });
  assert.equal(await request(1, async () => "accepted"), "accepted");
  await assert.rejects(request(0, async () => "stale"));
  await assert.rejects(runtime.withWorkspaceLease("browse_session_action", {}, async () => "unbound"));
  assert.throws(() => runtime.bindWorkspaceLease({ epoch: 1, until: future() }));
  assert.throws(() => runtime.bindWorkspaceLease({ epoch: 2, until: new Date(0).toISOString() }));

  let release;
  const gate = new Promise(resolveGate => { release = resolveGate; });
  let effects = 0;
  const queued = request(1, async () => {
    await gate;
    runtime.assertWorkspaceLease();
    effects += 1;
  });
  runtime.bindWorkspaceLease({ epoch: 2, until: future() });
  release();
  await assert.rejects(queued);
  assert.equal(effects, 0);
  assert.equal(await request(2, async () => "new owner"), "new owner");
  runtime.unbindWorkspaceLease();
  await assert.rejects(request(2, async () => "late finalizer"));
  assert.throws(() => runtime.renewWorkspaceLease({ epoch: 2, until: future() }));
  runtime.bindWorkspaceLease({ epoch: 4, until: future() });
  const originalNow = Date.now;
  const now = Date.now();
  runtime.renewWorkspaceLease({ epoch: 4, until: new Date(now + 120_000).toISOString() });
  try {
    Date.now = () => now + 61_000;
    assert.equal(await request(4, async () => "renewed"), "renewed");
    Date.now = () => now + 121_000;
    await assert.rejects(request(4, async () => "expired"));
  } finally {
    Date.now = originalNow;
  }
  let finishRequest;
  const finishGate = new Promise(resolveGate => { finishRequest = resolveGate; });
  const pending = request(4, async () => {
    await finishGate;
    runtime.assertWorkspaceLease();
  });
  runtime.revokeWorkspaceLease();
  const drained = runtime.drainWorkspaceRequests();
  finishRequest();
  await assert.rejects(pending);
  await drained;
  await assert.rejects(request(4, async () => "revoked"));
  assert.throws(() => runtime.bindWorkspaceLease({ epoch: 5, until: future() }));
});
