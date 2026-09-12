import { drainDialogs } from "./dialogs.js";
import type { SessionRecord } from "./types.js";
import { redactUrl } from "./utils.js";

export async function sessionView(session: SessionRecord, payload: object, previousUrl?: string) {
  const position = await session.page.evaluate(() => ({
    x: Math.round(scrollX), y: Math.round(scrollY),
    width: innerWidth, height: innerHeight,
    pageHeight: Math.max(document.body?.scrollHeight ?? 0, document.documentElement.scrollHeight),
  }));
  return {
    ...payload, url: redactUrl(session.page.url()), title: await session.page.title(), position,
    previousUrl: previousUrl && previousUrl !== session.page.url() ? redactUrl(previousUrl) : undefined,
    notes: [...session.requestGuard.drainNotes(), ...await drainDialogs(session.page)],
  };
}
