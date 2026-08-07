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
that exists only across the send, then removed. The extension is chosen from
the bytes, because WeChat decides how to treat an attachment by extension and
the sender's filename never reaches here.

`POST /fetch-image` — body is
`{"md5", "origin_md5", "length", "hd_length", "after_unix"}`, taken from the
`<img>` payload WeChat put in the message callback. Answers `200` with
`image/jpeg`, or `404`.

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
