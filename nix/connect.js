// maxx connect c9.max: ssh's ProxyCommand into another conversation's VM
// (guest.nix's Host *.max). It asks max at /connect/9 for an upgrade and
// then carries ssh's bytes both ways, which max joins to that VM's sshd;
// what max says when it refuses goes to stderr. See "Entering another
// conversation's VM" in docs/design/vm.md.
"use strict";

const http = require("node:http");
const { MAX } = require("./client.js");

function main([host, ...rest]) {
  const to = /^c#?(\d+)(\.max)?$/i.exec(host ?? "")?.[1];
  if (!to || rest.length) exit("maxx connect takes another conversation as ssh names it: c9.max", 2);
  const request = http.request(new URL(`/connect/${to}`, process.env.MAXX_URL ?? MAX), {
    headers: { Connection: "upgrade", Upgrade: "ssh" },
  });
  request.on("upgrade", (_, socket, head) => {
    if (head.length) process.stdout.write(head);
    process.stdin.pipe(socket);
    socket.pipe(process.stdout);
    socket.on("close", () => process.exit(0));
  });
  request.on("response", response => {
    let text = "";
    response.setEncoding("utf8");
    response.on("data", chunk => (text += chunk));
    response.on("end", () => exit(`c#${to}: ${text.trim() || response.statusCode}`, 1));
  });
  request.on("error", error => exit(`maxx connect: ${error.message}`, 1));
  request.end();
}

function exit(text, code) {
  process.stderr.write(`${text}\n`);
  process.exit(code);
}

main(process.argv.slice(2));
