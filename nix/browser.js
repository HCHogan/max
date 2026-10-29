// The browser in run_code's SDK: the VM's Chromium (guest.nix), which
// programs drive with Playwright over CDP; see "浏览器" in
// docs/rust-rewrite.md. The first program that wants it starts it. Its
// tabs outlive the program, and its profile the VM: the next program finds
// them as this one left them.
"use strict";

const { execFile } = require("node:child_process");
const { promisify } = require("node:util");

const CDP = "http://127.0.0.1:9222";

let connected;

// The browser's one context: its tabs, cookies and logins.
async function browser() {
  connected ??= connect().catch(error => {
    connected = undefined;
    throw error;
  });
  return (await connected).contexts()[0];
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
    throw new Error("这里没有浏览器，只有群 VM 里的 runner 带着它");
  }
  // Returns once the browser takes connections.
  await promisify(execFile)("systemctl", ["start", "max-browser.service"]);
  return chromium.connectOverCDP(CDP);
}

// The page as the model reads it: its title, address and accessibility
// tree, frames included, where each element has a ref, [ref=e5], that
// page.locator("aria-ref=e5") finds. Refs are the program's that took the
// snapshot; the next program takes its own, and an unchanged page gets
// the same ones. A selector narrows it to an element, depth to so many
// levels.
async function snapshot(page, { selector, depth } = {}) {
  if (typeof page?.ariaSnapshot !== "function") throw new TypeError("max.snapshot 要一个 Playwright 的 page");
  if (selector !== undefined && typeof selector !== "string") throw new TypeError("selector 要是选择器");
  if (depth !== undefined && (!Number.isInteger(depth) || depth < 1)) throw new TypeError("depth 要是正整数");
  const target = selector === undefined ? page : page.locator(selector).first();
  const tree = await target.ariaSnapshot({ mode: "ai", depth });
  return `${await page.title()}\n${page.url()}\n${tree}`;
}

module.exports = { browser, page, snapshot };
