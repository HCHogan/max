# wechat bridge

This service runs on the Windows host beside a WeChat client hooked by
[WeChat-Hook](https://github.com/aixed/WeChat-Hook). It exists because that
hook moves images through the local filesystem — it sends one by reading a path
on this machine's disk, and decrypts a received one the same way — while max
runs elsewhere and can do neither.

It is not a proxy for the hook's API. Text still goes straight from max to the
hook; only the two file-shaped operations come through here.

## Windows setup

1. Install WeChat **4.1.10.27** and drop `version.dll` beside the main
   executable. Disable WeChat's auto-update: the DLL's offsets are pinned to
   that exact build and a silent upgrade breaks everything at once.

2. Find where the client stores received images. On 4.x this is
   `%USERPROFILE%\Documents\xwechat_files\<wxid>_<suffix>\msg\attach` — the
   folder is the account's wxid plus a short per-installation suffix, so copy
   the name off disk rather than composing it. Pass it as
   `WECHAT_ATTACH_ROOTS`; only `/fetch-image` reads it, and only files written
   inside the request's time window are ever opened.

3. Get the binary there. Nothing needs to be installed on Windows — build it
   wherever max is built and copy it over:

   ```sh
   # from bridge/wechat on the Linux host
   GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
     go build -trimpath -ldflags="-s -w" -o max-wechat-bridge.exe .
   sudo tailscale file cp max-wechat-bridge.exe b650:
   ```

   Then on Windows, `tailscale file get .` collects it. Building natively with
   `go build -o max-wechat-bridge.exe .` works too if a Go toolchain is
   already installed there.

4. Run it:

   ```powershell
   $env:WECHAT_BRIDGE_LISTEN   = "100.x.x.x:8788"   # Tailscale address, not 0.0.0.0
   $env:WECHAT_BRIDGE_TOKEN    = "<long random token>"
   $env:WECHAT_ALLOWED_TARGETS = "12345678901@chatroom"
   $env:WECHAT_ATTACH_ROOTS    = "C:\Users\you\Documents\xwechat_files\wxid_you\msg\attach"
   .\max-wechat-bridge.exe
   ```

   Optional: `WECHAT_HOOK_URL` (default `http://127.0.0.1:30001`),
   `WECHAT_STAGING_DIR`, `WECHAT_MAX_IMAGE_BYTES` (default 32 MiB),
   `WECHAT_FETCH_WINDOW_SECONDS` (default 600).

Bind the Tailscale address. Every endpoint requires
`Authorization: Bearer $WECHAT_BRIDGE_TOKEN`, but the bearer check is the
second line of defence, not the first.

## Endpoints

`GET /health` — probes the hook with `GetSelfProfile` and reports whether the
DLL is loaded into a running client. Note that `/QueryDB/status` looks like the
obvious probe and is not one: on WeChat 4.x it answers `IsLogin: 0` while
plainly logged in.

`POST /send-image?to=<wxid|roomid>` — body is the raw image. Staged to a file
the hook is then told to read. The extension is chosen from the bytes, because
WeChat decides how to treat an attachment by extension and the sender's
filename never reaches here.

**The staged file outlives the call on purpose.** `/SendImgMsg` answers before
it has read the file, so deleting on return is a race — and one Go loses:
`ret: 0` came back and no picture ever arrived. The same delete in the same
order from a PowerShell probe landed every time, because an interpreter takes
milliseconds where a deferred call takes microseconds. That difference is what
made it a race rather than a rule. Staged files are now swept after
`WECHAT_STAGING_TTL_SECONDS` (default 120); only a failed send deletes at once.

`POST /fetch-image` — body is
`{"md5", "origin_md5", "length", "hd_length", "after_unix"}`, taken from the
`<img>` payload WeChat put in the message callback. Answers `200` with the
image, or `404`.

`GET /scan` — lists what `/fetch-image` would examine, decrypting nothing.
When a fetch misses, this answers the question underneath it: are the right
files even in view?

## One-time key setup

Received images are stored encrypted, and the hook cannot help: its
`/Decode_Pic` answers `{"ret":0,"retmsg":"success"}` on WeChat 4.x and writes
no file at all — the same way its database module reports a plainly logged-in
client as logged out. So the bridge decrypts them itself, which needs this
installation's two keys.

WeChat 4.x writes a `.dat` as a "V2" container: a 15-byte header, the first
1024 plaintext bytes under AES-128-ECB, then the remainder under a single-byte
XOR. Both keys are constants of the installation, not of the message — six
different thumbnails from one account share a byte-identical first ciphertext
block, which only happens when the same plaintext meets the same key.

Send yourself an image, take `md5` and `originsourcemd5` from the message
payload, and point the finder at the stored file:

```powershell
.\max-wechat-bridge.exe -find-key `
    "C:\...\msg\attach\...\Img\<hash>.dat" `
    <md5> <originsourcemd5>
```

It scans the running client's private memory for a printable 16-byte key,
tries each candidate against that file's first ciphertext block, and only
accepts one whose full decryption matches a digest WeChat itself published.
On success it prints the two lines to add to the environment:

```
WECHAT_IMAGE_AES_KEY=................
WECHAT_IMAGE_XOR=c0
```

`WECHAT_IMAGE_XOR` is optional — left out, the byte is rediscovered per file
against the published digest, which is correct but 256 times the work. It is
also derivable without touching the client at all: thumbnails stay JPEG even
when the full image is HEVC, so an `_t.dat`'s last two bytes are `FF D9` under
the XOR and name the byte twice over.

Reading another process's memory needs the privilege to do so; run the finder
from an elevated shell if it reports `OpenProcess` failing. The keys survive
until WeChat is reinstalled, so this is done once.

Hunt with a thumbnail (`*_t.dat`) and no digests. Thumbnails are JPEG, so the
key that opens one is recognisable by shape alone, and their decryption can be
checked at both ends — `FF D8 FF` at the start, `FF D9` at the end. A full
image is neither, as the next section explains, which makes it a poor sample:
a correct key would be discarded for producing something unrecognisable.

## What a stored image actually is

Decrypting is not the end of it. Verified against seven real messages:

```
.dat  →  AES-128-ECB(first 1024) + XOR 0xC0(rest)
      →  "wxgf" container, 16-byte header
      →  standard HEVC from the first Annex-B start code onward
      →  ffmpeg  →  a full-resolution image
```

So a thumbnail decrypts straight to a usable JPEG, while a full image decrypts
to WeChat's own `wxgf` wrapper around an HEVC still — `1280x1708` for one of
the samples here. Anything that wants pixels has to run the last step too.

**The published MD5 does not verify a full image.** Of seven, only two matched
their message's `md5` — exactly the two whose payload carried no `hdlength`.
Where an HD version exists, that digest describes something other than the
mid-size file on disk. What does hold, on all seven, is the decrypted length
matching the payload's `length` exactly, alongside the `wxgf` magic; that pair
is the identity check to rely on. Thumbnails have no published digest at all
and are verified as JPEGs.

So `/fetch-image` identifies a file by the published digest when that works and
by exact length plus magic when it does not, then converts before answering —
callers get an image, never a container to figure out.

The conversion needs **ffmpeg on this host**; without it only thumbnails can be
served, and the bridge says so at startup. Point `WECHAT_FFMPEG` at it if it is
not on `PATH`.

## Why the two directions are asymmetric

**Outbound is allowlisted.** The hook sends to any wxid it is handed, so a
bridge that forwarded an arbitrary target would be a "message anyone on this
account" service for whoever reached the port. Unconfigured targets are refused
before the hook sees them.

**Inbound is verified, not guessed.** The callback that announces an image
carries no path, and the hook's database module cannot supply one on WeChat 4.x
— it enumerates no databases and cannot open one by name. What the callback
does carry is `md5` and `originsourcemd5`. So `/fetch-image` decrypts candidate
files and compares digests; byte length and modification time only decide what
to try first. **No digest match means no image**, which leaves max degrading
exactly as it does without this bridge. Attaching a different picture from the
same chat would be far worse than the feature being absent, and time-window
correlation on its own would eventually do precisely that.

The `md5` field is assumed to be the digest of the *decrypted* image. If a real
message ever fails to match, that assumption is where to look first — the
payload also carries perceptual hashes (`secHashInfoBase64`) that would survive
a re-encode, and could back a second matcher.

## Known risk

DLL injection into a reverse-engineered client, with offsets pinned to one
build. Run a throwaway account. 封号风险自担。
