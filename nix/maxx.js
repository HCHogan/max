// maxx: Max's tools on the command line, for shell commands and programs
// in any language in a group's VM, and for max itself, which runs what
// the guest's systemd does with it. Its options come from the tools'
// schemas, the host's as its service lists them and the guest's own from
// local.json: nothing here is about one tool. See "maxx" in
// docs/rust-rewrite.md.
//
//   maxx                                   the tools
//   maxx history --help                    one tool's arguments
//   maxx history --who 小明 --limit 5       a call: its result as JSON
//   maxx history 示波器                     the same, by position
//   maxx history '{"query": "示波器"}'      or as JSON; - reads it from stdin
//   maxx agent start --task - <<'EOF'      a value of - is standard input
//   maxx say -- '--help 是什么'            after --, every word is a text
//   maxx units list                        one of the guest's own, by its words
//   maxx events --after 123                the group's rows after #123 as
//                                          they come, a JSON line each;
//                                          --full has each as data too
//
// The result goes to stdout; a failure's reason to stderr, with exit
// status 1. A wrong command line exits with 2. One of the guest's own
// given its words and a JSON object alone never comes here: bin/maxx
// runs it itself (maxx.nix), which is how the host calls, and how this
// does once it has read the options.
"use strict";

const { once } = require("node:events");
const { MAX } = require("./client.js");
const { LOCAL, open } = require("./tools.js");

// Where /work is: tests have their own.
const WORK = process.env.MAXX_WORK ?? "/work";

class Usage extends Error {}

// A tool as the command line names it: the guest's own by its words.
const named = tool => (tool.words ? tool.words.join(" ") : tool.name);

async function main(argv) {
  const tools = open({ url: process.env.MAXX_URL ?? MAX, work: WORK });
  const [first, second] = argv;
  if (first === undefined || first === "help" || first === "--help" || first === "-h") {
    return [listing(await listed(tools)), 0];
  }
  // One of the guest's own, by its words as they are written and no
  // other way; else one of the host's.
  let tool =
    LOCAL.find(tool => tool.words.length === 2 && tool.words[0] === first && tool.words[1] === second) ??
    LOCAL.find(tool => tool.words.length === 1 && tool.words[0] === first);
  const rest = argv.slice(tool ? tool.words.length : 1);
  if (!tool) {
    const group = LOCAL.filter(tool => tool.words.length === 2 && tool.words[0] === first);
    if (group.length) {
      const lines = [`${first} takes one of:`, ...table(group)].join("\n");
      if (second === undefined || second === "--help" || second === "-h") return [lines, 0];
      const meant = group.find(tool => plain(tool.words[1]) === plain(second));
      throw new Usage(meant ? `there is no ${first} ${second}; it is written maxx ${named(meant)}` : `there is no ${first} ${second}\n${lines}`);
    }
    // Its words run together, as a program has its name: the words
    // themselves are the only way to write it, and it is told them.
    const meant = LOCAL.find(tool => plain(named(tool)) === plain(first));
    if (meant) throw new Usage(`there is no tool named ${first}; it is written maxx ${named(meant)}`);
    const name = first.replaceAll("-", "_");
    if (rest.length === 1 && rest[0].startsWith("{") && braced(rest[0])) {
      // Its arguments as one JSON object, which no schema is needed to
      // read: the host isn't asked for its list first, and says itself
      // whether it has such a tool.
      tool = { name };
    } else {
      const all = await listed(tools);
      tool = all.find(tool => !tool.words && tool.name === name);
      if (!tool) throw new Usage(`there is no tool named ${first}; there are: ${all.map(named).join(", ")}`);
    }
  }
  if (tool.stream) return [await follow(tools, rest, tool), 0];
  if (asksHelp(rest)) return [help(tool), 0];
  const args = await parse(rest, tool.inputSchema);
  const outcome = await tools.request(tool.name, args);
  if (!outcome.ok) return [`${named(tool)}: ${outcome.error.message} (${outcome.error.code})`, 1];
  const value = outcome.value;
  return [typeof value === "string" ? value : JSON.stringify(value, null, 2), 0];
}

async function listed(tools) {
  const outcome = await tools.list();
  if (!outcome.ok) throw new Failed(`${outcome.error.message} (${outcome.error.code})`);
  return outcome.value;
}

class Failed extends Error {}

// A name without what joins its words: agent-start, agent_start and
// "agent start" are one.
const plain = text => text.replace(/[-_ ]/g, "");

// --help among the options, or -h in the first place: further on, -h is
// a text's, and after -- so is --help.
function asksHelp(words) {
  const end = words.indexOf("--");
  return words[0] === "-h" || (end < 0 ? words : words.slice(0, end)).includes("--help");
}

// A line for each tool: its name, and what it is.
function table(tools) {
  const width = Math.max(...tools.map(tool => named(tool).length));
  return tools.map(tool => `  ${named(tool).padEnd(width)}  ${tool.description}`);
}

function listing(tools) {
  return [
    "Usage: maxx <tool> --<argument> <value> ..., or maxx <tool> '{\"argument\": value}', or maxx <tool> - to read JSON from standard input.",
    "A value of - is read from standard input: maxx agent start --task - <<'EOF'.",
    "The result is JSON, printed to standard output; a failure prints why to standard error and exits with 1. maxx <tool> --help shows a tool's arguments.",
    "Tools:",
    ...table(tools),
  ].join("\n");
}

// maxx events: the rows, a JSON line each, until whoever reads them
// stops. Its arguments are read as a call's; a message's number may be
// written as the records write it, #123.
async function follow(tools, words, tool) {
  if (asksHelp(words)) return EVENTS_HELP;
  const numbered = words.map(word => word.replace(/^(--after=)?#(\d+)$/, "$1$2"));
  const { after, full } = await parse(numbered, tool.inputSchema);
  // Whoever read the rows is gone.
  process.stdout.on("error", () => process.exit(0));
  const told = (why, wait) => process.stderr.write(`maxx events: ${why}; reconnecting in ${wait / 1000} seconds\n`);
  for await (const row of tools.follow({ after, full, told })) {
    if (!process.stdout.write(`${JSON.stringify(row)}\n`)) await once(process.stdout, "drain");
  }
}

const EVENTS = LOCAL.find(tool => tool.name === "events").description;

const EVENTS_HELP = [
  `events: ${EVENTS}`,
  "Prints a line of JSON for each message: {id, at, sender, person, by, reply_to, text}.",
  "  text is written as in history; person is the sender's number, and [mention#person] mentions them;",
  "  by is max or program for what Max itself or a program said, and absent for what the people said; reply_to is the message it replies to.",
  "It reconnects by itself, and goes on from the last message before the break.",
  "Arguments:",
  "  --after <number>  from after this message, catching up on at most the latest 1000; without it, from now.",
  "  --full            each line with the row as data too, as maxx rows gives it: row, and people, the person behind each of its accounts.",
].join("\n");

function help(tool) {
  const properties = Object.entries(tool.inputSchema?.properties ?? {});
  const required = new Set(tool.inputSchema?.required ?? []);
  const flag = ([property, schema]) => {
    const kind = types(schema).map(type => KINDS[type] ?? type).join(" or ");
    const must = required.has(property) ? ", required" : "";
    const about = schema?.description ? `: ${schema.description}` : "";
    return `  --${property} (${kind}${must})${about}`;
  };
  const lines = [`${named(tool)}: ${tool.description}`];
  // How it is used, as the system prompt says it of a turn's tools: all
  // an agent, which is told of none, has to go on.
  if (tool.guide && tool.guide !== tool.description) lines.push(tool.guide);
  lines.push(...(properties.length ? ["Arguments:", ...properties.map(flag)] : ["No arguments."]));
  const returns = shape(tool.outputSchema);
  if (returns) lines.push(`Returns: ${returns}`);
  return lines.join("\n");
}

// What a schema takes, written as a type: { name: string, said?: string }.
function shape(schema) {
  if (!schema || typeof schema !== "object") return "";
  if (Array.isArray(schema.anyOf)) return [...new Set(schema.anyOf.map(shape).filter(Boolean))].join(" | ");
  const kinds = Array.isArray(schema.type) ? schema.type : schema.type ? [schema.type] : [];
  const one = kind => {
    if (kind === "integer") return "number";
    if (kind === "array") {
      const item = shape(schema.items) || "unknown";
      return item.includes(" | ") ? `(${item})[]` : `${item}[]`;
    }
    if (kind !== "object") return kind;
    const required = new Set(schema.required ?? []);
    const fields = Object.entries(schema.properties ?? {}).map(([name, field]) => `${name}${required.has(name) ? "" : "?"}: ${shape(field) || "unknown"}`);
    return fields.length ? `{ ${fields.join(", ")} }` : "object";
  };
  return [...new Set(kinds.map(one))].join(" | ");
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
// true, --no-name for false, and - for a text's value to read it from
// stdin; a JSON object, or - for one on stdin; and words by position,
// for the required arguments first and then the rest in order. After --
// every word is by position, whatever it begins with.
async function parse(words, schema) {
  const properties = schema?.properties ?? {};
  const args = {};
  const positional = [];
  let options = true;
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
    if (!options) positional.push(word);
    else if (word === "--") options = false;
    else if (word === "-") Object.assign(args, object(await stdin(), "standard input", "; a text is read from it as an argument's value, --text -"));
    else if (word.startsWith("{") && braced(word)) Object.assign(args, object(word, "the argument"));
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
      // Text too long or too odd for a command line, as a heredoc gives
      // it: without the newlines that end it.
      if (text === "-" && kinds.includes("string")) text = (await stdin()).replace(/\n+$/, "");
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

// Whether a word that begins with a brace is the arguments as JSON: it
// is a JSON object, or begins as a program writes one, {" (bin/maxx
// takes those for JSON too). Any other is a text: a command in braces,
// { make; } 2>&1, or a face.
function braced(word) {
  if (word.startsWith('{"')) return true;
  try {
    const value = JSON.parse(word);
    return Boolean(value) && typeof value === "object" && !Array.isArray(value);
  } catch {
    return false;
  }
}

function object(text, where, hint = "") {
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    throw new Usage(`${where} isn't JSON: ${error.message}${hint}`);
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Usage(`${where} must be a JSON object`);
  return value;
}

// Standard input, read once however often it is asked for.
let given;
function stdin() {
  given ??= (async () => {
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    return Buffer.concat(chunks).toString("utf8");
  })();
  return given;
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
