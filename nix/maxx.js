// maxx: Max's tools on the command line, for shell commands and programs
// in any language in a group's VM. It calls the MCP service as the run
// it is part of, by the token in MAXX_TOKEN, which shell commands and
// run_code's programs have; without one, as a program Max keeps in the
// VM, such as a unit's, which has no show or video. Its options come from the
// tools' schemas, as the service lists them: nothing here is about one
// tool. See "maxx" in docs/rust-rewrite.md.
//
//   maxx                                   the tools this caller may call
//   maxx history --help                    one tool's arguments
//   maxx history --who 小明 --limit 5       a call: its result as JSON
//   maxx history 示波器                     the same, by position
//   maxx history '{"query": "示波器"}'      or as JSON; - reads it from stdin
//   maxx events --after 123                the group's rows after #123 as
//                                          they come, a JSON line each
//
// The result goes to stdout; a failure's reason to stderr, with exit
// status 1. A wrong command line exits with 2.
"use strict";

const { once } = require("node:events");
const { MCP, connect, events } = require("./client.js");
const { watch } = require("./video.js");

// Where /work is: tests have their own.
const WORK = process.env.MAXX_WORK ?? "/work";
const TIME = { type: ["number", "string"] };

// The runner's own calls, which tools/list leaves out; show only a run's.
// One with a call of its own makes it, in place of the host's.
const OWN = {
  show: { tool: "max.image", argument: "path", run: true, description: "Shows yourself a picture under /work, after the result of this shell or run_code: maxx show <path>" },
  video: {
    tool: "max.video",
    argument: "path",
    run: true,
    options: { start: { ...TIME, description: 'where to start: seconds, or "1:30"' }, end: { ...TIME, description: "where to stop" } },
    call: (client, { path, start, end }) => watch(client.request, WORK, path, { start, end }),
    description: "Shows yourself a piece of video, after the result of this shell or run_code, at most 10 minutes at a time: maxx video <path> [--start 1:30] [--end 2:00]",
  },
  file: { tool: "max.file", argument: "handle", description: "Copies a file of this chat's records into /work/chat, and returns {path, name, size}: maxx file file#123.0" },
};

// Not a call: the timeline, from the host's /events.
const EVENTS = "The chat's new messages, a line of JSON each, for as long as it runs: maxx events [--after <number>]";

class Usage extends Error {}

async function main(argv) {
  const token = process.env.MAXX_TOKEN || undefined;
  const mcp = process.env.MAXX_MCP ?? MCP;
  const client = connect({ url: mcp, token });
  const own = Object.fromEntries(Object.entries(OWN).filter(([, call]) => token || !call.run));
  const [first, ...rest] = argv;
  if (first === undefined || first === "help" || first === "--help" || first === "-h") {
    return [listing(await tools(client), own), 0];
  }
  if (first === "events") return [await follow(new URL("/events", mcp).href, rest), 0];
  const name = first.replaceAll("-", "_");
  const called = own[name];
  let tool;
  if (called) {
    const properties = { [called.argument]: { type: "string" }, ...called.options };
    tool = { name: called.tool, description: called.description, inputSchema: { type: "object", properties, required: [called.argument] } };
  } else {
    const listed = await tools(client);
    tool = listed.find(tool => tool.name === name);
    if (!tool) throw new Usage(`there is no tool named ${first}; there are: ${[...listed.map(tool => tool.name), ...Object.keys(own)].join(", ")}`);
  }
  const shown = called ? name : tool.name;
  if (rest.includes("--help") || rest.includes("-h")) return [help(shown, tool), 0];
  const args = await parse(rest, tool.inputSchema);
  const outcome = await (called?.call ? called.call(client, args) : client.request(tool.name, args));
  if (!outcome.ok) return [`${shown}: ${outcome.error.message} (${outcome.error.code})`, 1];
  const value = outcome.value;
  return [typeof value === "string" ? value : JSON.stringify(value, null, 2), 0];
}

async function tools(client) {
  const outcome = await client.list();
  if (!outcome.ok) throw new Failed(`${outcome.error.message} (${outcome.error.code})`);
  return outcome.value;
}

class Failed extends Error {}

function listing(tools, own) {
  const width = Math.max(...[...tools.map(tool => tool.name), ...Object.keys(own), "events"].map(name => name.length));
  const line = (name, description) => `  ${name.padEnd(width)}  ${description}`;
  return [
    "Usage: maxx <tool> --<argument> <value> ..., or maxx <tool> '{\"argument\": value}', or maxx <tool> - to read JSON from standard input.",
    "The result is JSON, printed to standard output; a failure prints why to standard error and exits with 1. maxx <tool> --help shows a tool's arguments.",
    "Tools:",
    ...tools.map(tool => line(tool.name, tool.description)),
    ...Object.entries(own).map(([name, call]) => line(name, call.description)),
    line("events", EVENTS),
  ].join("\n");
}

// maxx events: the rows, a JSON line each, until whoever reads them stops.
async function follow(url, words) {
  if (words.includes("--help") || words.includes("-h")) return EVENTS_HELP;
  let after;
  for (let i = 0; i < words.length; i++) {
    const [flag, inline] = words[i].startsWith("--") ? split(words[i].slice(2)) : [undefined];
    if (flag !== "after") throw new Usage(`events takes only --after <number>, not ${words[i]}`);
    const text = inline ?? words[++i];
    if (text === undefined || !/^#?\d+$/.test(text)) throw new Usage("--after takes a message's number");
    after = Number(text.replace("#", ""));
  }
  // Whoever read the rows is gone.
  process.stdout.on("error", () => process.exit(0));
  const told = (why, wait) => process.stderr.write(`maxx events: ${why}; reconnecting in ${wait / 1000} seconds\n`);
  for await (const row of events({ url, after, told })) {
    if (!process.stdout.write(`${JSON.stringify(row)}\n`)) await once(process.stdout, "drain");
  }
}

const EVENTS_HELP = [
  `events: ${EVENTS}`,
  "Prints a line of JSON for each message: {id, at, sender, person, by, reply_to, text}.",
  "  text is written as in history; person is the sender's number, and [mention#person] mentions them;",
  "  by is max or program for what Max itself or a program said, and absent for what the people said; reply_to is the message it replies to.",
  "It reconnects by itself, and goes on from the last message before the break.",
  "Arguments:",
  "  --after <number>  from after this message, catching up on at most the latest 1000; without it, from now.",
].join("\n");

function help(name, tool) {
  const properties = Object.entries(tool.inputSchema?.properties ?? {});
  const required = new Set(tool.inputSchema?.required ?? []);
  const flag = ([property, schema]) => {
    const kind = types(schema).map(type => KINDS[type] ?? type).join(" or ");
    const must = required.has(property) ? ", required" : "";
    const about = schema?.description ? `: ${schema.description}` : "";
    return `  --${property} (${kind}${must})${about}`;
  };
  return [`${name}: ${tool.description}`, ...(properties.length ? ["Arguments:", ...properties.map(flag)] : ["No arguments."])].join("\n");
}

const KINDS = { boolean: "true/false" };

// The JSON types a schema takes, but null: an argument left out is null.
function types(schema) {
  if (!schema || typeof schema !== "object") return [];
  if (Array.isArray(schema.anyOf)) return [...new Set(schema.anyOf.flatMap(types))];
  const type = Array.isArray(schema.type) ? schema.type : schema.type ? [schema.type] : [];
  return type.filter(type => type !== "null");
}

// The call's arguments: --name value, --name=value, a bare --name for
// true, --no-name for false; JSON, or - for JSON on stdin; and words by
// position, for the required arguments first and then the rest in order.
async function parse(words, schema) {
  const properties = schema?.properties ?? {};
  const args = {};
  const positional = [];
  const property = flag => {
    const name = flag.replaceAll("-", "_");
    if (!(name in properties)) {
      const known = Object.keys(properties).map(name => `--${name}`).join(", ") || "none";
      throw new Usage(`there is no argument --${flag}; there are: ${known}`);
    }
    return name;
  };
  for (let i = 0; i < words.length; i++) {
    const word = words[i];
    if (word === "-") Object.assign(args, object(await stdin(), "standard input"));
    else if (word.startsWith("{")) Object.assign(args, object(word, "the argument"));
    else if (word.startsWith("--") && word.length > 2) {
      const [flag, inline] = split(word.slice(2));
      if (inline === undefined && flag.startsWith("no-") && !(flag.replaceAll("-", "_") in properties)) {
        args[property(flag.slice(3))] = false;
        continue;
      }
      const name = property(flag);
      const kinds = types(properties[name]);
      let text = inline;
      if (text === undefined) {
        if (kinds.length === 1 && kinds[0] === "boolean") {
          args[name] = true;
          continue;
        }
        if (i + 1 >= words.length) throw new Usage(`--${flag} needs a value`);
        text = words[++i];
      }
      put(args, name, text, properties[name]);
    } else positional.push(word);
  }
  const required = schema?.required ?? [];
  const open = [...required, ...Object.keys(properties).filter(name => !required.includes(name))].filter(name => !(name in args));
  for (const word of positional) {
    const name = open.shift();
    if (name === undefined) throw new Usage(`one argument too many: ${word}`);
    put(args, name, word, properties[name]);
  }
  return args;
}

function split(flag) {
  const at = flag.indexOf("=");
  return at < 0 ? [flag, undefined] : [flag.slice(0, at), flag.slice(at + 1)];
}

// A value given as text, as its schema reads it; an array's flag given
// again adds an item.
function put(args, name, text, schema) {
  const kinds = types(schema);
  if (kinds.includes("array") && !text.startsWith("[")) {
    const items = Array.isArray(args[name]) ? args[name] : [];
    items.push(read(name, text, schema.items ?? (schema.anyOf ?? []).find(variant => variant?.items)?.items));
    args[name] = items;
  } else args[name] = read(name, text, schema);
}

function read(name, text, schema) {
  const kinds = types(schema);
  if (kinds.includes("integer") || kinds.includes("number")) {
    if (text.trim() !== "" && !Number.isNaN(Number(text))) return Number(text);
    if (!kinds.includes("string")) throw new Usage(`--${name} takes a number, not ${JSON.stringify(text)}`);
  }
  if (kinds.includes("boolean") && (text === "true" || text === "false")) return text === "true";
  if (kinds.includes("string") || kinds.length === 0) return text;
  if (kinds.includes("boolean")) throw new Usage(`--${name} takes true or false`);
  try {
    return JSON.parse(text);
  } catch {
    throw new Usage(`--${name} is written as JSON`);
  }
}

function object(text, where) {
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    throw new Usage(`${where} isn't JSON: ${error.message}`);
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Usage(`${where} must be a JSON object`);
  return value;
}

async function stdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

function exit(text, code) {
  const stream = code === 0 ? process.stdout : process.stderr;
  stream.write(text === "" ? "" : `${text}\n`, () => process.exit(code));
}

main(process.argv.slice(2)).then(
  ([text, code]) => exit(text, code),
  error => {
    if (error instanceof Usage) exit(`maxx: ${error.message}`, 2);
    else if (error instanceof Failed) exit(`maxx: ${error.message}`, 1);
    else exit(`maxx: ${error.stack ?? error}`, 1);
  },
);
