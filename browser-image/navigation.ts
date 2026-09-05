import { errors, type Page, type Response } from "playwright-core";
import type { WaitStrategy } from "./runtime-types.js";

export async function navigatePage(page: Page, url: string, waitUntil: WaitStrategy, timeout: number): Promise<{
  response: Response | null;
  navigation: { complete: boolean; waitUntil: WaitStrategy };
}> {
  const started = Date.now();
  const response = await page.goto(url, { waitUntil: "commit", timeout });
  try {
    await page.waitForLoadState(waitUntil, { timeout: Math.max(1, Math.min(10000, timeout - (Date.now() - started))) });
    return { response, navigation: { complete: true, waitUntil } };
  } catch (error) {
    if (!(error instanceof errors.TimeoutError) || !response || page.isClosed() || page.url() !== response.url()) throw error;
    return { response, navigation: { complete: false, waitUntil } };
  }
}
