import { assertWorkspaceLease } from "./workspace-lease.js";
import type { Frame } from "playwright-core";
import type { SessionRecord } from "./types.js";

type CollectOptions = { selector?: string; maxChars: number; maxElements: number; maxScrolls: number; waitMs: number; timeout: number };

export async function collectPage(session: SessionRecord, frame: Frame, input: CollectOptions) {
  const started = Date.now();
  const originalUrl = session.page.url();
  const originalFrameUrl = frame.url();
  const seen = new Set<string>();
  const chunks: string[] = [];
  let chars = 0, scrolls = 0, stagnant = 0;
  let reason = "scroll limit";
  for (;;) {
    assertWorkspaceLease();
    session.requestGuard.assertAllowed();
    if (session.page.url() !== originalUrl || frame.url() !== originalFrameUrl) { reason = "page navigated; selectors are stale"; break; }
    if (Date.now() - started >= input.timeout) { reason = "time budget"; break; }
    const view = await frame.evaluate(({ selector, limit }) => {
      const root = selector ? document.querySelector(selector) : document.body;
      if (!root) throw new Error("collect selector did not match");
      const viewport = selector ? root.getBoundingClientRect() : { top: 0, bottom: innerHeight, left: 0, right: innerWidth };
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
      const text: string[] = [];
      let inspected = 0;
      while (walker.nextNode() && inspected++ < 50000 && text.length < limit) {
        const parent = walker.currentNode.parentElement;
        if (!parent || parent.closest("script,style,noscript,template,[hidden]")) continue;
        const bounds = parent.getBoundingClientRect();
        const style = getComputedStyle(parent);
        if (!bounds.width || !bounds.height || style.visibility === "hidden" || style.display === "none" || bounds.bottom < viewport.top || bounds.top > viewport.bottom || bounds.right < viewport.left || bounds.left > viewport.right) continue;
        const value = walker.currentNode.textContent?.replace(/\s+/g, " ").trim();
        if (value) text.push(value.slice(0, 30000));
      }
      const target = selector ? root : document.scrollingElement!;
      return { text, y: target.scrollTop, height: target.scrollHeight, viewport: target.clientHeight };
    }, { selector: input.selector, limit: input.maxElements });
    let added = 0;
    for (const chunk of view.text) {
      if (seen.has(chunk)) continue;
      seen.add(chunk);
      const remaining = input.maxChars - chars - (chunks.length ? 1 : 0);
      if (remaining <= 0) break;
      const bounded = [...chunk].slice(0, remaining).join("");
      chunks.push(bounded);
      chars += [...bounded].length + (chunks.length > 1 ? 1 : 0);
      added++;
    }
    if (chars >= input.maxChars) { reason = "character budget"; break; }
    stagnant = added ? 0 : stagnant + 1;
    if (stagnant >= 2) { reason = "no new content"; break; }
    if (scrolls >= input.maxScrolls) break;
    // Scroll even at the current end once: lazy pages may append on that event.
    await frame.evaluate(selector => {
      const root = selector ? document.querySelector(selector)! : document.scrollingElement!;
      root.scrollBy(0, Math.max(100, root.clientHeight * 0.8));
    }, input.selector);
    scrolls++;
    await session.page.waitForTimeout(Math.min(input.waitMs, Math.max(0, input.timeout - (Date.now() - started))));
  }
  return { text: chunks.join("\n"), scrolls, reason };
}
