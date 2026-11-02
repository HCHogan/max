// opencli in a group's VM (opencli.nix): its commands run in the VM's
// Chromium, each in a tab of its own that closes when the command ends,
// so that they don't navigate the page Max's programs are on, nor each
// other's. opencli finds the browser at OPENCLI_CDP_ENDPOINT, which here
// is a server of this script's that opens the tab when opencli first asks
// for the browser's targets: a command that doesn't use the browser
// doesn't start it. See "opencli" under 浏览器 in docs/rust-rewrite.md.
"use strict";

const { execFile, spawn } = require("node:child_process");
const http = require("node:http");
const { constants } = require("node:os");
const { promisify } = require("node:util");

const CDP = "http://127.0.0.1:9222";

const [opencli, ...args] = process.argv.slice(2);

// The command's tab, once opencli has asked for it.
let tab;

async function open() {
  // Returns once the browser takes connections.
  await promisify(execFile)("systemctl", ["start", "max-browser.service"]);
  const response = await fetch(`${CDP}/json/new?about:blank`, { method: "PUT" });
  if (!response.ok) throw new Error(`浏览器没开出标签页：${response.status}`);
  return response.json();
}

async function close() {
  const target = await tab?.catch(() => undefined);
  if (target) await fetch(`${CDP}/json/close/${target.id}`).catch(() => {});
}

// The browser's targets, as opencli reads them: the command's tab alone.
const targets = http.createServer(async (request, response) => {
  const { pathname } = new URL(request.url, "http://localhost");
  if (pathname !== "/json" && pathname !== "/json/list") {
    response.writeHead(404).end();
    return;
  }
  try {
    tab ??= open();
    const target = await tab;
    response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify([target]));
  } catch (error) {
    response.writeHead(502).end(error.message);
  }
});

targets.listen(0, "127.0.0.1", () => {
  const env = {
    ...process.env,
    OPENCLI_CDP_ENDPOINT: `http://127.0.0.1:${targets.address().port}`,
    // No update check, nor its notice: Nix pins the version.
    CI: "1",
  };
  const child = spawn(opencli, args, { stdio: "inherit", env });
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    process.on(signal, () => child.kill(signal));
  }
  child.on("exit", async (code, signal) => {
    await close();
    targets.close();
    process.exit(code ?? 128 + (constants.signals[signal] ?? 0));
  });
});
