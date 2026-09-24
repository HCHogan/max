import type { BrowserContext, Page, Request, Route } from "playwright-core";
import { DnsResolutionError, parseAndValidateBrowserRequestUrl, validateBrowserRequestUrl } from "./policy.js";
import { MAX_GUARDED_REQUESTS } from "./config.js";
import type { RequestGuard } from "./types.js";

// The budget and fatal error belong to an operation, never the lifetime of a
// context. DNS failures and disallowed subresources abort only that resource;
// a disallowed top-level document, or a disallowed target that was reached
// anyway, fails the current operation. Keep bounded host-only diagnostics.
export async function installRequestGuard(context: BrowserContext): Promise<RequestGuard> {
  let inspected = 0;
  let fatal: Error | undefined;
  const notes = new Set<string>();
  function hostOf(url: string) {
    try { return new URL(url).hostname; } catch { return "invalid URL"; } // no URL secrets in notes
  }
  function note(url: string, reason: string) {
    if (notes.size < 20) notes.add(`blocked host ${hostOf(url)}: ${reason}`);
  }
  function fail(url: string) {
    fatal ??= new Error(`Blocked unsafe browser request: host ${hostOf(url)} is a private, reserved or disallowed target.`);
  }
  function blocked(url: string, error: unknown, document: boolean) {
    if (error instanceof DnsResolutionError) {
      note(url, "DNS did not resolve; resource skipped");
    } else if (document) {
      fail(url);
    } else {
      note(url, "private, reserved or disallowed target; resource skipped");
    }
  }
  async function allowed(url: string, document: boolean) {
    if (++inspected > MAX_GUARDED_REQUESTS) {
      note(url, "operation request budget exhausted; resource skipped");
      return false;
    }
    try { await validateBrowserRequestUrl(url); return true; }
    catch (error) { blocked(url, error, document); return false; }
  }
  function disallowedLiteral(url: string) {
    try { parseAndValidateBrowserRequestUrl(url); return false; } catch { return true; }
  }
  context.on("request", request => {
    if (disallowedLiteral(request.url())) blocked(request.url(), undefined, topLevelDocument(request));
  });
  // Routed requests to disallowed targets are aborted and never answered. A
  // network response therefore means the request bypassed routing.
  context.on("response", response => {
    if (/^https?:/i.test(response.url()) && disallowedLiteral(response.url())) fail(response.url());
  });
  await context.route("**/*", async (route: Route) => {
    if (await allowed(route.request().url(), topLevelDocument(route.request()))) await route.continue().catch(() => undefined);
    else await route.abort("blockedbyclient").catch(() => undefined);
  });
  await context.routeWebSocket(/.*/, async socket => {
    if (await allowed(socket.url(), false)) socket.connectToServer();
    else await socket.close({ code: 1008, reason: "Blocked by server policy" }).catch(() => undefined);
  });
  return {
    beginOperation() { inspected = 0; fatal = undefined; },
    drainNotes() { const result = [...notes]; notes.clear(); return result; },
    assertAllowed() { if (fatal) throw fatal; },
    watchPage(page: Page) {
      page.on("websocket", socket => {
        if (disallowedLiteral(socket.url())) note(socket.url(), "private, reserved or disallowed target; resource skipped");
      });
    },
  };
}

// Service-worker requests have no frame; they are never the page document.
function topLevelDocument(request: Request) {
  try { return request.isNavigationRequest() && request.frame().parentFrame() === null; }
  catch { return false; }
}
