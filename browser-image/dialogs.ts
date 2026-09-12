import type { Page } from "playwright-core";

type Answer = { response: "accept" | "dismiss"; promptText?: string };
const recorders = new WeakMap<Page, { next?: Answer; notes: string[]; pending: Set<Promise<void>> }>();

export function installDialogs(page: Page) {
  const state = { notes: [] as string[], pending: new Set<Promise<void>>() } as { next?: Answer; notes: string[]; pending: Set<Promise<void>> };
  recorders.set(page, state);
  page.on("dialog", dialog => {
    const answer = state.next ?? { response: "dismiss" };
    state.next = undefined;
    const pending = (async () => {
      let outcome: string = answer.response;
      try {
        if (answer.response === "accept") await dialog.accept(answer.promptText);
        else await dialog.dismiss();
      } catch { outcome = "answer failed"; }
      if (state.notes.length < 10) state.notes.push(`dialog ${dialog.type()} auto-${outcome}: ${dialog.message().replace(/\s+/g, " ").slice(0, 200)}`);
    })();
    state.pending.add(pending);
    void pending.finally(() => state.pending.delete(pending));
  });
}

export function answerNextDialog(page: Page, answer: Answer) {
  const state = recorders.get(page);
  if (!state) throw new Error("dialog recorder unavailable");
  state.next = answer;
}

export async function drainDialogs(page: Page) {
  const state = recorders.get(page);
  if (!state) return [];
  await Promise.allSettled([...state.pending]);
  return state.notes.splice(0);
}
