import type { BrowserContextOptions } from "playwright-core";
import { closeActiveSessions, getSession, handleSessionStart } from "./sessions.js";
import { closeActiveBrowsers } from "./browser-runtime.js";
import { buildSuccessContent, buildToolError } from "./responses.js";
import type { SessionStartToolInput } from "./schemas.js";
import { bindWorkspaceLease, drainWorkspaceRequests, renewWorkspaceLease, revokeWorkspaceLease, unbindWorkspaceLease } from "./workspace-lease.js";

let closing: Promise<void> | undefined;

export async function handleWorkspaceTool(name: string, input: Record<string, unknown>) {
  try {
    if (name === "max_workspace_bind") {
      bindWorkspaceLease(input as { epoch: number; until: string });
      return buildSuccessContent({ bound: true });
    }
    if (name === "max_workspace_unbind") {
      unbindWorkspaceLease();
      return buildSuccessContent({ released: true });
    }
    if (name === "max_workspace_renew") {
      renewWorkspaceLease(input as { epoch: number; until: string });
      return buildSuccessContent({ renewed: true });
    }
    if (name === "max_workspace_revoke") {
      revokeWorkspaceLease();
      closing ??= (async () => {
        await closeActiveSessions();
        await drainWorkspaceRequests();
        await closeActiveSessions();
        await closeActiveBrowsers();
      })().finally(() => { closing = undefined; });
      await closing;
      return buildSuccessContent({ closed: true });
    }
    const session = await getSession(String(input.sessionId));
    if (name === "max_workspace_keepalive") return buildSuccessContent({ alive: true });
    if (name === "max_workspace_checkpoint") {
      await session.op;
      const storage = await session.context.storageState();
      if (Buffer.byteLength(JSON.stringify(storage), "utf8") > 10_000_000) throw new Error("checkpoint too large");
      return buildSuccessContent({ storage });
    }
    return buildToolError("unknown workspace operation");
  } catch {
    return buildToolError("workspace operation failed");
  }
}

export async function startWorkspace(input: SessionStartToolInput & { storage?: BrowserContextOptions["storageState"] }) {
  try {
    const result = await handleSessionStart({ ...input, exclude_addons: ["UBO"], enable_cache: true, viewport: { width: 1280, height: 800 } }, input.storage);
    if (!("isError" in result)) return result;
    // The start error is already proxy-sanitized; a restore error could echo
    // saved cookies or storage, so only a fresh start reports its cause.
    if (input.storage !== undefined) return buildToolError("workspace start or restore failed");
    const cause = result.content.find(item => item.type === "text")?.text ?? "";
    // EAGAIN at spawn is the service's process/thread budget, not a broken
    // browser: say so, or the model abandons the browser for the whole task.
    const exhausted = /\bEAGAIN\b|Resource temporarily unavailable/.test(cause)
      ? "this conversation's browser service is at its process limit (too many concurrent browser sessions); wait for other tasks to finish, then retry. "
      : "";
    return buildToolError(`workspace start failed: ${exhausted}${cause.slice(0, 300)}`);
  } catch {
    return buildToolError("workspace restore failed");
  }
}
