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
    const result = await handleSessionStart(input, input.storage);
    return "isError" in result ? buildToolError("workspace start or restore failed") : result;
  } catch {
    return buildToolError("workspace restore failed");
  }
}
