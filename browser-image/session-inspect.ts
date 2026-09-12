import { withTimeout } from "./utils.js";
import { z } from "zod";
import { sessionIdShape, frameSchema } from "./schema/tools.js";
import { getSession, runSessionExclusive, sessionToolErrorKind, sessionSanitizedError } from "./sessions.js";
import { runGuardedPageRead } from "./browser-runtime.js";
import { resolveReadFrame } from "./sequence.js";
import { buildFindPayload, buildFormsPayload, buildLinksPayload, buildOutlinePayload, extractPageContent } from "./extractors.js";
import { buildSuccessContent, buildToolError } from "./responses.js";
import { sessionView } from "./session-view.js";
import { answerNextDialog } from "./dialogs.js";
import { collectPage } from "./collect.js";
import type { ScreenshotResult, SessionRecord } from "./types.js";

export const sessionInspectShape = {
  ...sessionIdShape,
  action: z.enum(["read", "find", "links", "forms", "screenshot", "dialog", "collect"]),
  maxChars: z.number().int().min(512).max(30000).default(6000),
  maxElements: z.number().int().min(1).max(200).default(40),
  selector: z.string().max(2000).optional(), frame: frameSchema,
  mode: z.enum(["text", "outline"]).default("text"),
  query: z.string().min(1).max(500).optional(),
  response: z.enum(["accept", "dismiss"]).default("dismiss"),
  promptText: z.string().max(2000).optional(),
  maxScrolls: z.number().int().min(1).max(20).default(5),
  waitMs: z.number().int().min(0).max(2000).default(250),
  timeout: z.number().int().min(100).max(60000).default(10000),
};
export type InspectInput = z.infer<z.ZodObject<typeof sessionInspectShape>>;

export async function handleSessionInspect(input: InspectInput) {
  let session: SessionRecord | undefined;
  try {
    const current = await getSession(input.sessionId);
    session = current;
    return await runSessionExclusive(current, async () => {
      const previousUrl = current.page.url();
      const frame = await resolveReadFrame(current.page, input.frame);
      let screenshot: ScreenshotResult | undefined;
      const notes: string[] = [];
      const payload = await withTimeout(runGuardedPageRead(current.page, current.requestGuard, async () => {
        let text: string;
        switch (input.action) {
          case "read": {
            if (input.mode === "outline") {
              const result = await buildOutlinePayload(frame, current.lastNavigationResponse, input.maxElements, input.selector);
              text = result.headings.map(item => `${item.selector} | ${"#".repeat(item.level)} ${item.text}`).join("\n");
              text += "\nLandmarks: " + result.landmarks.join(", ");
            } else {
              const selector = input.selector ?? (await frame.locator("article").count() ? "article" : undefined);
              const result = await extractPageContent(frame, "text", input.maxChars, selector);
              text = result.value;
              if (!result.found) notes.push("selector did not match an element");
              if (result.truncated) notes.push("article text truncated; narrow selector or raise maxChars");
            }
            break;
          }
          case "find": {
            if (!input.query) throw new Error("find requires query");
            const result = await buildFindPayload(frame, current.lastNavigationResponse, input.query, Math.min(50, input.maxElements), 200, input.selector);
            text = result.matches.map(item => `${item.selector} | ${item.text}`).join("\n") || "No matching text.";
            break;
          }
          case "links": {
            const result = await buildLinksPayload(frame, current.lastNavigationResponse, input.maxElements, input.selector);
            text = result.links.map(item => `${item.text} | ${item.href}`).join("\n") || "No links.";
            break;
          }
          case "forms": {
            const result = await buildFormsPayload(frame, current.lastNavigationResponse, Math.min(20, input.maxElements), input.maxElements, input.selector);
            text = result.forms.map(form => JSON.stringify(form)).join("\n") || "No forms.";
            break;
          }
          case "screenshot": {
            // CSS scale produces a viewport-width image even at deviceScaleFactor > 1.
            const bytes = await current.page.screenshot({ type: "jpeg", quality: 65, fullPage: false, scale: "css", timeout: input.timeout });
            if (bytes.length > 2_000_000) throw new Error("viewport screenshot exceeds the 2 MB attachment budget");
            screenshot = { base64: bytes.toString("base64"), mimeType: "image/jpeg", screenshotMetadata: { requested: true, included: true, maxBytes: 2_000_000, type: "jpeg", fullPage: false } };
            text = "Viewport screenshot captured.";
            break;
          }
          case "dialog":
            answerNextDialog(current.page, { response: input.response, promptText: input.promptText });
            text = `Next dialog will be ${input.response}ed; later dialogs default to dismiss.`;
            break;
          case "collect": {
            const result = await collectPage(current, frame, input);
            text = result.text;
            notes.push(`collect stopped: ${result.reason}; ${result.scrolls} scrolls`);
            break;
          }
        }
        if ([...text].length > input.maxChars) notes.push("content truncated to maxChars");
        return { text: [...text].slice(0, input.maxChars).join("") };
      }), input.timeout, "Session inspection");
      const view = await sessionView(current, payload, previousUrl);
      view.notes.push(...notes);
      return buildSuccessContent(view, screenshot);
    });
  } catch (error) {
    return buildToolError(sessionSanitizedError(error, session), sessionToolErrorKind(session));
  }
}
