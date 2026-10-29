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

// The interactive elements of a page (or a frame), each with a CSS
// selector that finds it: the Haskell version's snapshot, without its text
// and ARIA tree, which a program reads with Playwright when it wants them.
async function snapshot(page, { selector, limit = 100 } = {}) {
  if (typeof page?.evaluate !== "function") throw new TypeError("max.snapshot 要一个 Playwright 的 page");
  if (selector !== undefined && typeof selector !== "string") throw new TypeError("selector 要是 CSS 选择器");
  if (!Number.isInteger(limit) || limit < 1) throw new TypeError("limit 要是正整数");
  const found = await page.evaluate(interactive, { selector, limit });
  if (!found) throw new Error(`页面上没有 ${selector}`);
  return { url: page.url(), title: await page.title(), ...found };
}

// Runs in the page, so it uses nothing from outside itself. null when the
// selector finds nothing.
function interactive({ selector, limit }) {
  const root = selector ? document.querySelector(selector) : document.body ?? document.documentElement;
  if (!root) return null;

  const squeezed = text => (text ?? "").replace(/\s+/g, " ").trim().slice(0, 300);
  const ident = value => CSS.escape(value);
  // The element's id, or a path of tags from the nearest ancestor with one
  // (at most 8 steps), told apart from siblings by class and position.
  const selectorFor = element => {
    if (element.id) return `#${ident(element.id)}`;
    const path = [];
    let current = element;
    while (current && current !== document.documentElement && path.length < 8) {
      if (current !== element && current.id) {
        path.unshift(`#${ident(current.id)}`);
        break;
      }
      let part = current.tagName.toLowerCase();
      if (current.classList.length > 0) {
        part += `.${Array.from(current.classList).slice(0, 2).map(ident).join(".")}`;
      }
      const parent = current.parentElement;
      if (parent) {
        const same = Array.from(parent.children).filter(child => child.tagName === current.tagName);
        if (same.length > 1) part += `:nth-of-type(${same.indexOf(current) + 1})`;
      }
      path.unshift(part);
      current = parent;
    }
    return path.join(" > ");
  };
  const roleOf = element => {
    const explicit = element.getAttribute("role");
    if (explicit) return explicit;
    const tag = element.tagName.toLowerCase();
    if (tag === "a" && element.hasAttribute("href")) return "link";
    if (tag === "button") return "button";
    if (tag === "select") return "combobox";
    if (tag === "textarea") return "textbox";
    if (tag === "input") {
      const type = (element.getAttribute("type") ?? "text").toLowerCase();
      if (["button", "submit", "reset"].includes(type)) return "button";
      if (type === "checkbox" || type === "radio") return type;
      return "textbox";
    }
    return undefined;
  };
  const nameOf = element => {
    const direct = ["aria-label", "alt", "title", "placeholder"]
      .map(attribute => element.getAttribute(attribute)?.trim())
      .find(Boolean);
    if (direct) return direct.slice(0, 300);
    const labelledBy = element.getAttribute("aria-labelledby");
    const labelled = labelledBy && squeezed(labelledBy.split(/\s+/).map(id => document.getElementById(id)?.textContent ?? "").join(" "));
    return labelled || squeezed(element.textContent) || undefined;
  };
  const visible = element => {
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return false;
    const style = getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" && style.visibility !== "collapse";
  };

  const candidates = [
    "a[href]",
    "button",
    "input",
    "select",
    "textarea",
    "[role]",
    "[tabindex]:not([tabindex='-1'])",
    "[contenteditable='true']",
  ].join(",");
  const elements = [];
  let truncated = false;
  for (const element of [...(root.matches(candidates) ? [root] : []), ...root.querySelectorAll(candidates)]) {
    if (!visible(element)) continue;
    if (elements.length >= limit) {
      truncated = true;
      break;
    }
    const rect = element.getBoundingClientRect();
    const name = nameOf(element);
    const text = squeezed(element.textContent) || undefined;
    elements.push({
      tag: element.tagName.toLowerCase(),
      selector: selectorFor(element),
      role: roleOf(element),
      name,
      // Only when it says more than the name.
      text: text === name ? undefined : text,
      bounds: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
    });
  }
  return { elements, truncated };
}

module.exports = { browser, page, snapshot };
