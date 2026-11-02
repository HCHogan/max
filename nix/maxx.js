// maxx: Max's tools on the command line, for shell commands and programs
// in any language in a group's VM. It calls the MCP service as the run
// it is part of, by the token in MAXX_TOKEN, which shell commands and
// run_code's programs have; without one, as a program Max keeps in the
// VM, such as a unit's, with fewer tools. Its options come from the
// tools' schemas, as the service lists them: nothing here is about one
// tool. See "maxx" in docs/rust-rewrite.md.
//
//   maxx                                   the tools this caller may call
//   maxx history --help                    one tool's arguments
//   maxx history --who 小明 --limit 5       a call: its result as JSON
//   maxx history 示波器                     the same, by position
//   maxx history '{"query": "示波器"}'      or as JSON; - reads it from stdin
//
// The result goes to stdout; a failure's reason to stderr, with exit
// status 1. A wrong command line exits with 2.
"use strict";

const { MCP, connect } = require("./client.js");

// The runner's own calls, which tools/list leaves out; show only a run's.
const OWN = {
  show: { tool: "max.image", argument: "path", run: true, description: "把 /work 下的一张图给你自己看，跟在这次 shell 或 run_code 的结果后面：maxx show 路径" },
  file: { tool: "max.file", argument: "handle", description: "把本群记录里的一个文件拷进 /work/chat，返回 {path, name, size}：maxx file file#123.0" },
};

class Usage extends Error {}

async function main(argv) {
  const token = process.env.MAXX_TOKEN || undefined;
  const client = connect({ url: process.env.MAXX_MCP ?? MCP, token });
  const own = Object.fromEntries(Object.entries(OWN).filter(([, call]) => token || !call.run));
  const [first, ...rest] = argv;
  if (first === undefined || first === "help" || first === "--help" || first === "-h") {
    return [listing(await tools(client), own), 0];
  }
  const name = first.replaceAll("-", "_");
  const called = own[name];
  let tool;
  if (called) {
    tool = { name: called.tool, description: called.description, inputSchema: { type: "object", properties: { [called.argument]: { type: "string" } }, required: [called.argument] } };
  } else {
    const listed = await tools(client);
    tool = listed.find(tool => tool.name === name);
    if (!tool) throw new Usage(`没有 ${first} 这个工具；能用的：${[...listed.map(tool => tool.name), ...Object.keys(own)].join("、")}`);
  }
  const shown = called ? name : tool.name;
  if (rest.includes("--help") || rest.includes("-h")) return [help(shown, tool), 0];
  const args = await parse(rest, tool.inputSchema);
  const outcome = await client.request(tool.name, args);
  if (!outcome.ok) return [`${shown}: ${outcome.error.message}（${outcome.error.code}）`, 1];
  const value = outcome.value;
  return [typeof value === "string" ? value : JSON.stringify(value, null, 2), 0];
}

async function tools(client) {
  const outcome = await client.list();
  if (!outcome.ok) throw new Failed(`${outcome.error.message}（${outcome.error.code}）`);
  return outcome.value;
}

class Failed extends Error {}

function listing(tools, own) {
  const width = Math.max(...[...tools.map(tool => tool.name), ...Object.keys(own)].map(name => name.length));
  const line = (name, description) => `  ${name.padEnd(width)}  ${description}`;
  return [
    "用法：maxx 工具名 --参数 值 ...，或者 maxx 工具名 '{\"参数\": 值}'，或者 maxx 工具名 - 从标准输入读 JSON。",
    "结果是 JSON，打印到标准输出；失败时原因打印到标准错误，退出码 1。maxx 工具名 --help 看参数。",
    "工具：",
    ...tools.map(tool => line(tool.name, tool.description)),
    ...Object.entries(own).map(([name, call]) => line(name, call.description)),
  ].join("\n");
}

function help(name, tool) {
  const properties = Object.entries(tool.inputSchema?.properties ?? {});
  const required = new Set(tool.inputSchema?.required ?? []);
  const flag = ([property, schema]) => {
    const kind = types(schema).map(type => KINDS[type] ?? type).join(" 或 ");
    const must = required.has(property) ? "，必填" : "";
    const about = schema?.description ? `：${schema.description}` : "";
    return `  --${property}（${kind}${must}）${about}`;
  };
  return [`${name}：${tool.description}`, ...(properties.length ? ["参数：", ...properties.map(flag)] : ["没有参数。"])].join("\n");
}

const KINDS = { string: "字符串", integer: "整数", number: "数", boolean: "true/false", array: "数组", object: "对象" };

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
      const known = Object.keys(properties).map(name => `--${name}`).join("、") || "没有";
      throw new Usage(`没有 --${flag} 这个参数；能用的：${known}`);
    }
    return name;
  };
  for (let i = 0; i < words.length; i++) {
    const word = words[i];
    if (word === "-") Object.assign(args, object(await stdin(), "标准输入"));
    else if (word.startsWith("{")) Object.assign(args, object(word, "参数"));
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
        if (i + 1 >= words.length) throw new Usage(`--${flag} 后面要有值`);
        text = words[++i];
      }
      put(args, name, text, properties[name]);
    } else positional.push(word);
  }
  const required = schema?.required ?? [];
  const open = [...required, ...Object.keys(properties).filter(name => !required.includes(name))].filter(name => !(name in args));
  for (const word of positional) {
    const name = open.shift();
    if (name === undefined) throw new Usage(`多了一个参数：${word}`);
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
    if (!kinds.includes("string")) throw new Usage(`--${name} 要一个数，不是 ${JSON.stringify(text)}`);
  }
  if (kinds.includes("boolean") && (text === "true" || text === "false")) return text === "true";
  if (kinds.includes("string") || kinds.length === 0) return text;
  if (kinds.includes("boolean")) throw new Usage(`--${name} 要 true 或 false`);
  try {
    return JSON.parse(text);
  } catch {
    throw new Usage(`--${name} 要写成 JSON`);
  }
}

function object(text, where) {
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    throw new Usage(`${where}不是 JSON：${error.message}`);
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Usage(`${where}要是一个 JSON 对象`);
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
