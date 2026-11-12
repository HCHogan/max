// max.video's half in the VM, which the runner and maxx share: the copy
// of a video the model watches, made here with ffmpeg so that the host
// never decodes one. A frame a second, as Gemini samples them, at most
// 640 pixels a side, the sound in mono: ten minutes come to a few MiB,
// which every model call left in the turn sends again. The copy is left
// for the host as a picture is (shown.js): the host stores it and reads
// its length. See "Multimodal results" in docs/rust-rewrite.md.
"use strict";

const { execFile } = require("node:child_process");
const { promisify } = require("node:util");
const { NOBODY, failed, local: guest, scratch, show } = require("./shown.js");

const run = promisify(execFile);
// The most seconds one piece shows; the host holds a call's videos to it
// together.
const MOST = 600;
const SCALE = "scale='min(640,iw)':'min(640,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2";

// Shows the model the video at path from start to end; work is where
// /work is. Its outcome, as a call's: {ok: true, value: {seconds}}, how
// long the piece is as far as the file says, or {ok: false, error: {code,
// message}}.
async function watch(work, path, { start, end } = {}) {
  if (!process.env.MAX_CALL) return failed("unavailable", NOBODY);
  const from = time(start);
  const to = time(end);
  if (from === null || to === null) return failed("bad_time", 'start and end take seconds, or a time such as "1:30" or "1:02:03.5"');
  const local = guest(work, path);
  let length;
  try {
    const { stdout } = await run("ffprobe", ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", local]);
    length = Number(stdout.trim());
  } catch (error) {
    return failed("not_a_video", `can't read ${path}: ${said(error, local)}`);
  }
  const begin = from ?? 0;
  const stop = to ?? length;
  if (Number.isFinite(length) && begin >= length) return failed("bad_time", `start is past the end: ${path} is only ${Math.round(length)} seconds long`);
  if (stop <= begin) return failed("bad_time", "end must come after start");
  if (stop - begin > MOST) {
    return failed("too_long", `this is ${Math.round(stop - begin)} seconds, and at most ${MOST / 60} minutes are shown at a time: cut a piece with start and end`);
  }
  const [written, shown] = await scratch(work, ".mp4");
  const cut = ["-ss", String(begin), ...(to === undefined ? [] : ["-t", String(stop - begin)])];
  try {
    await run("ffmpeg", [
      "-nostdin", "-v", "error", ...cut, "-i", local,
      "-map", "0:v:0", "-map", "0:a:0?", "-vf", `fps=1,${SCALE}`,
      "-c:v", "libx264", "-preset", "veryfast", "-crf", "28", "-pix_fmt", "yuv420p",
      "-c:a", "aac", "-ac", "1", "-b:a", "32k", "-movflags", "+faststart", written,
    ]);
  } catch (error) {
    return failed("not_a_video", `can't convert ${path}: ${said(error, local)}`);
  }
  await show("video", shown);
  const seconds = stop - begin;
  return { ok: true, value: Number.isFinite(seconds) ? { seconds: Math.max(1, Math.round(seconds)) } : {} };
}

// Seconds, from a number or "1:30", "1:02:03.5"; undefined when not
// given, null when not a time.
function time(value) {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "number") return Number.isFinite(value) && value >= 0 ? value : null;
  if (typeof value !== "string" || !/^\d+(:\d{1,2}){0,2}(\.\d+)?$/.test(value)) return null;
  return value.split(":").reduce((total, part) => total * 60 + Number(part), 0);
}

// What ffmpeg said last, without the file's name before it.
function said(error, file) {
  const lines = String(error.stderr ?? "").trim().split("\n").filter(Boolean);
  const last = lines.at(-1) ?? error.message;
  return last.startsWith(`${file}: `) ? last.slice(file.length + 2) : last;
}

module.exports = { watch };
