import type { BrowserContext, Page, Route } from "playwright-core";
import { DnsResolutionError, parseAndValidateBrowserRequestUrl, validateBrowserRequestUrl } from "./policy.js";
import { MAX_GUARDED_REQUESTS } from "./config.js";
import type { RequestGuard } from "./types.js";

// The budget and fatal error belong to an operation, never the lifetime of a
// context. DNS failures abort only that resource; private/reserved targets fail
// the current operation. Keep bounded host-only diagnostics for the next view.
export async function installRequestGuard(context: BrowserContext): Promise<RequestGuard> {
  let inspected = 0;
  let fatal: Error | undefined;
  const notes = new Set<string>();
  function note(url: string, reason: string) {
    let host = "invalid URL";
    try { host = new URL(url).hostname; } catch { /* no URL secrets in notes */ }
    if (notes.size < 20) notes.add(`blocked host ${host}: ${reason}`);
  }
  function blocked(url: string, error: unknown) {
    if (error instanceof DnsResolutionError) {
      note(url, "DNS did not resolve; resource skipped");
    } else {
      note(url, "private, reserved or disallowed target");
      fatal ??= new Error("Blocked unsafe browser request.");
    }
  }
  async function allowed(url: string) {
    if (++inspected > MAX_GUARDED_REQUESTS) {
      note(url, "operation request budget exhausted; resource skipped");
      return false;
    }
    try { await validateBrowserRequestUrl(url); return true; }
    catch (error) { blocked(url, error); return false; }
  }
  context.on("request", request => {
    try { parseAndValidateBrowserRequestUrl(request.url()); }
    catch (error) { blocked(request.url(), error); }
  });
  await context.route("**/*", async (route: Route) => {
    if (await allowed(route.request().url())) await route.continue().catch(() => undefined);
    else await route.abort("blockedbyclient").catch(() => undefined);
  });
  await context.routeWebSocket(/.*/, async socket => {
    if (await allowed(socket.url())) socket.connectToServer();
    else await socket.close({ code: 1008, reason: "Blocked by server policy" }).catch(() => undefined);
  });
  return {
    beginOperation() { inspected = 0; fatal = undefined; },
    drainNotes() { const result = [...notes]; notes.clear(); return result; },
    assertAllowed() { if (fatal) throw fatal; },
    watchPage(page: Page) {
      page.on("websocket", socket => {
        try { parseAndValidateBrowserRequestUrl(socket.url()); }
        catch (error) { blocked(socket.url(), error); }
      });
    },
  };
}
