// What a call shows the model after its result: the pictures and videos a
// program hands over with tools.show and tools.video, and a command with
// maxx show and maxx video. Nothing is asked of the host for it. A call's
// unit has its directory in MAX_CALL (max-jobs.sh), and each thing to
// show is a line of its `shown` there: maxx units run gives the list back on
// the call's line, and the host reads the files from /work as it puts the
// result together. One it can't show, it says so in the result. What
// isn't part of a call (a background command, an agent, a unit of Max's)
// has no MAX_CALL, and nobody to show anything to. See "Multimodal
// results" in docs/rust-rewrite.md.
"use strict";

const { randomUUID } = require("node:crypto");
const { appendFile, mkdir, stat, writeFile } = require("node:fs/promises");
const { basename } = require("node:path");

const failed = (code, message) => ({ ok: false, error: { code, message } });
const NOBODY = "nobody is there to see it: only a shell or run_code call of Max's own shows Max a picture or a video";

// The guest's file for path, as the host reads paths: relative ones are
// under /work, which tests have their own of.
const local = (work, path) => (path.startsWith("/") ? path.replace(/^\/work(?=\/|$)/, work) : `${work}/${path}`);

// A file of this call's own in /work, where the host reads it: where to
// write it, and what the host is told. The next calls clear them away.
async function scratch(work, extension = "") {
  const dir = `.max/shown/${basename(process.env.MAX_CALL)}`;
  await mkdir(`${work}/${dir}`, { recursive: true });
  const name = `${randomUUID()}${extension}`;
  return [`${work}/${dir}/${name}`, `/work/${dir}/${name}`];
}

// Leaves path, a file under /work, for the model to see: an "image" or a
// "video".
async function show(kind, path) {
  await appendFile(`${process.env.MAX_CALL}/shown`, `${JSON.stringify({ kind, path })}\n`);
}

// A picture for the model: a file under /work, or a picture's bytes. Its
// outcome, as a call's: {ok: true, value: {path}} or {ok: false, error}.
// Whether it decodes, and whether there is room for it, the host says in
// the result.
async function image(work, src) {
  if (!process.env.MAX_CALL) return failed("unavailable", NOBODY);
  if (src instanceof Uint8Array) {
    const [written, path] = await scratch(work);
    await writeFile(written, src);
    await show("image", path);
    return { ok: true, value: { path } };
  }
  try {
    if (!(await stat(local(work, src))).isFile()) return failed("not_a_picture", `${src} isn't a file`);
  } catch {
    return failed("not_found", `${src} doesn't exist`);
  }
  const path = src.startsWith("/") ? src : `/work/${src}`;
  await show("image", path);
  return { ok: true, value: { path } };
}

module.exports = { NOBODY, failed, image, local, scratch, show };
