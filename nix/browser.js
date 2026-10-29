// The browser in run_code's SDK: camoufox, a Firefox, which programs drive
// with Playwright; see "浏览器" in docs/rust-rewrite.md. A run's first
// max.browser() starts it, headless and over a pipe; it goes with the
// runner's process, so nothing of it outlives the run but what the program
// saved in /work.
"use strict";

let started;

// A new page in a context of its own, with options as newContext takes
// them: a login saved by storageState, say. One browser serves the run.
async function browser(options = {}) {
  if (!options || typeof options !== "object" || Array.isArray(options)) {
    throw new TypeError("max.browser 的参数要是一个对象，交给 newContext");
  }
  started ??= launch().catch(error => {
    started = undefined;
    throw error;
  });
  const context = await (await started).newContext(options);
  return context.newPage();
}

async function launch() {
  let camoufox;
  try {
    camoufox = await import("camoufox-js");
  } catch (error) {
    if (error.code !== "ERR_MODULE_NOT_FOUND") throw error;
    throw new Error("这里没有浏览器，只有群 VM 里的 runner 带着它");
  }
  // camoufox shows pages only the fonts of the system it poses as, which
  // have no bold Chinese; the guest's Noto CJK are let through as well.
  const fonts = ["SC", "TC", "HK", "JP", "KR"].map(region => `Noto Sans CJK ${region}`);
  return camoufox.Camoufox({ headless: true, fonts });
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

module.exports = { browser, snapshot };
