import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const directory = pathToFileURL(process.argv[2]);
const { trackBrowser, activeBrowserCount } = await import(new URL("browser-runtime.js", directory));
const { handleWorkspaceTool } = await import(new URL("workspace-tools.js", directory));
let connected = true;
let attempts = 0;
trackBrowser({
  isConnected: () => connected,
  close: async () => {
    attempts += 1;
    if (attempts === 1) throw new Error("fixture close failure");
    connected = false;
  },
});
assert.equal((await handleWorkspaceTool("max_workspace_revoke", {})).isError, true);
assert.equal(activeBrowserCount(), 1);
assert.ok(!(await handleWorkspaceTool("max_workspace_revoke", {})).isError);
assert.equal(activeBrowserCount(), 0);
assert.equal(attempts, 2);
console.log("PASS failed browser closure stays tracked and can be retried while revoked");
