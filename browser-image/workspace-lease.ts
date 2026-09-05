import { AsyncLocalStorage } from "node:async_hooks";

type Lease = { epoch: number; until: string };
const requests = new AsyncLocalStorage<Lease | undefined>();
const pendingRequests = new Set<Promise<unknown>>();
let epoch = 0;
let revoked = false;
let expires = 0;

export function bindWorkspaceLease(lease: Lease): void {
  const until = Date.parse(lease.until);
  if (revoked || !Number.isSafeInteger(lease.epoch) || lease.epoch <= epoch || !Number.isFinite(until) || until <= Date.now()) {
    throw new Error("workspace lease rejected");
  }
  epoch = lease.epoch;
  expires = until;
}

export function revokeWorkspaceLease(): void {
  revoked = true;
}

export function unbindWorkspaceLease(): void {
  epoch += 1;
  expires = 0;
}

export function renewWorkspaceLease(lease: Lease): void {
  const until = Date.parse(lease.until);
  if (revoked || lease.epoch !== epoch || !Number.isFinite(until) || until <= Date.now()) {
    throw new Error("workspace lease renewal rejected");
  }
  expires = Math.max(expires, until);
}

export async function drainWorkspaceRequests(): Promise<void> {
  await Promise.allSettled([...pendingRequests]);
}

export function assertWorkspaceLease(): void {
  const lease = requests.getStore();
  if (revoked || (epoch !== 0 && (!lease || lease.epoch !== epoch || Date.now() >= expires))) {
    throw new Error("workspace execution was fenced");
  }
}

export async function withWorkspaceLease<Result>(name: string, input: unknown, operation: () => Promise<Result>): Promise<Result> {
  if (name.startsWith("max_workspace_")) return operation();
  const lease = (input as { _maxLease?: Lease })._maxLease;
  const pending = requests.run(lease, async () => {
    assertWorkspaceLease();
    return operation();
  });
  pendingRequests.add(pending);
  try {
    return await pending;
  } finally {
    pendingRequests.delete(pending);
  }
}
