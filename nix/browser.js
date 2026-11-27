// The browser in run_code's SDK: the VM's Chromium (guest.nix), which
// programs drive with Playwright over CDP; see "The browser" in
// docs/design/tools.md. The first program that wants it starts it. Its
// tabs outlive the program, and its profile the VM: the next program finds
// them as this one left them. A program of Max's own requires this file
// as /run/max/browser.js.
"use strict";

const { execFile } = require("node:child_process");
const { promisify } = require("node:util");

const CDP = "http://127.0.0.1:9222";

// How long an action waits for its element, and a navigation for its
// page, unless the call gives a timeout: Playwright's 30 seconds for both
// had a click on what isn't there cost half a minute.
const ACTION_MS = 10_000;
const NAVIGATION_MS = 30_000;

// Where a document keeps its last snapshot, for the next program: a
// property of its window, which goes when the page navigates, as the
// refs do.
const KEPT = "__maxSnapshot";

// How long a program's start waits for a tab's kept snapshot.
const RECALL_MS = 3_000;

let connected;

// The browser's one context: its tabs, cookies and logins.
function browser() {
  connected ??= connect().catch(error => {
    connected = undefined;
    throw error;
  });
  return connected;
}

// The tab last opened or brought to the front (page.bringToFront()), or a
// new one if there is none. A program that connects later gets
// context.pages() in whatever order Chromium attaches them, so the order
// is the browser's own list's, most recently active first.
async function page() {
  const context = await browser();
  const pages = context.pages();
  if (pages.length === 0) return context.newPage();
  const ids = await Promise.all(pages.map(async page => {
    const session = await context.newCDPSession(page);
    try {
      return (await session.send("Target.getTargetInfo")).targetInfo.targetId;
    } finally {
      await session.detach();
    }
  }));
  const list = await (await fetch(`${CDP}/json/list`)).json();
  const newest = list.find(target => target.type === "page" && ids.includes(target.id));
  return newest ? pages[ids.indexOf(newest.id)] : pages.at(-1);
}

async function connect() {
  let chromium;
  try {
    ({ chromium } = require("playwright-core"));
  } catch (error) {
    if (error.code !== "MODULE_NOT_FOUND") throw error;
    throw new Error("there is no browser here: only the runner in a chat's VM has one");
  }
  // Returns once the browser takes connections.
  await promisify(execFile)("systemctl", ["start", "max-browser.service"]);
  const context = (await chromium.connectOverCDP(CDP)).contexts()[0];
  context.setDefaultTimeout(ACTION_MS);
  context.setDefaultNavigationTimeout(NAVIGATION_MS);
  context.on("page", guard);
  await Promise.all(context.pages().map(page => {
    guard(page);
    return recall(page);
  }));
  return context;
}

// The refs each page's last snapshot gave, as this program may use them:
// `shown` all of them, and `now` what each that still names its element
// is called in this program (see recall). A page without a snapshot has
// no entry.
const refs = new WeakMap();

const REF = /\[ref=((?:f\d+)?e\d+)\]/;

// A ref that names nothing is refused where the locator is made:
// Playwright would wait the action's whole timeout for it and then say
// only that it waited.
function guard(page) {
  const locator = page.locator.bind(page);
  page.locator = (selector, options) => {
    const ref = /^aria-ref=((?:f\d+)?e\d+)/.exec(selector)?.[1];
    if (ref !== undefined) {
      const known = refs.get(page);
      if (known === undefined) {
        throw new Error(`aria-ref=${ref}: the page has no snapshot the ref could be of: it navigated since, or none was taken. Take one with max.snapshot(page)`);
      }
      if (!known.shown.has(ref)) {
        throw new Error(`aria-ref=${ref}: the page's last snapshot has no such ref. Take a new one with max.snapshot(page)`);
      }
      const now = known.now.get(ref);
      if (now === undefined) {
        throw new Error(`aria-ref=${ref}: the page has changed at or above this element since the snapshot that showed the ref, so which element it was can't be told. Take a new one with max.snapshot(page)`);
      }
      selector = `aria-ref=${now}${selector.slice(`aria-ref=${ref}`.length)}`;
    }
    return locator(selector, options);
  };
}

// A snapshot's lines as two snapshots are compared by: without the
// refs, and without what an element is in at the moment ([active],
// [checked], [expanded]), which comes and goes without moving one.
function lines(tree) {
  return tree.split("\n").map(line => ({
    ref: REF.exec(line)?.[1],
    text: line.replace(/ \[[^\]\n]*\]/g, ""),
  }));
}

function shown(tree) {
  return lines(tree).flatMap(line => line.ref ?? []);
}

// Makes the refs of the snapshot an earlier program took usable in this
// one. A ref is a number Playwright's script in the page gives an element
// when a snapshot first comes to it, and that script is each connection's
// own: a new one counts from e1 again, in the page's order, while the
// earlier one kept the numbers it had given and went on counting for
// what was new. So the page is snapshot again as it was then, and the
// two are read side by side: up to the first line that differs, a line
// of each is the same element, and the ref the model has is the one this
// program's snapshot gives it. After that line which element a ref was
// can't be told, and those are refused.
async function recall(page) {
  let timer;
  const late = new Promise(resolve => {
    timer = setTimeout(resolve, RECALL_MS);
  });
  const read = (async () => {
    const kept = await page.evaluate(key => window[key], KEPT);
    if (typeof kept?.tree !== "string") return;
    const then = lines(kept.tree);
    const here = lines(await take(page, { ...kept, timeout: RECALL_MS }));
    const now = new Map();
    for (let i = 0; i < then.length && then[i].text === here[i]?.text; i++) {
      if (then[i].ref !== undefined && here[i].ref !== undefined) now.set(then[i].ref, here[i].ref);
    }
    refs.set(page, { shown: new Set(shown(kept.tree)), now });
  })();
  // A tab that doesn't answer, or one that closed, keeps no program
  // waiting: its refs are unknown, and using one says to take a snapshot.
  await Promise.race([read.catch(() => {}), late]);
  clearTimeout(timer);
}

function take(page, { selector, depth, timeout }) {
  const target = selector === undefined ? page : page.locator(selector).first();
  return target.ariaSnapshot({ mode: "ai", depth, timeout });
}

// The page as the model reads it: its title, address and accessibility
// tree, frames included, where each element has a ref, [ref=e5], that
// page.locator("aria-ref=e5") finds. The refs are of the page's last
// snapshot, and later programs may use them too while the page above
// the element stays as it was (see recall). A selector narrows it to an
// element, depth to so many levels.
async function snapshot(page, { selector, depth } = {}) {
  if (typeof page?.ariaSnapshot !== "function") throw new TypeError("max.snapshot takes a Playwright page");
  if (selector !== undefined && typeof selector !== "string") throw new TypeError("selector must be a selector");
  if (depth !== undefined && (!Number.isInteger(depth) || depth < 1)) throw new TypeError("depth must be a positive integer");
  const tree = await take(page, { selector, depth });
  const all = shown(tree);
  refs.set(page, { shown: new Set(all), now: new Map(all.map(ref => [ref, ref])) });
  // Kept in the document for the next program; one that is navigating
  // away has no use for it.
  await page.evaluate(([key, kept]) => {
    Object.defineProperty(window, key, { value: kept, configurable: true });
  }, [KEPT, { tree, selector, depth }]).catch(() => {});
  return `${await page.title()}\n${page.url()}\n${tree}`;
}

module.exports = { browser, page, snapshot };
