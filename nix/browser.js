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

// The newest tab, or a new one if there is none.
async function page() {
  const context = await browser();
  return context.pages().at(-1) ?? context.newPage();
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
