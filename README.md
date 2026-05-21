# max

A QQ group-chat agent in Haskell, talking to QQ via [NapCatQQ](https://napneko.github.io/) over the OneBot 11 protocol.

This repo is Phase 1: just enough plumbing to answer `@bot ping` with `pong` in a group. No LLM, no RAG, no tools yet.

## Layout

```
flake.nix          devenv 2.0 shell (GHC 9.12, postgres+pgvector, tooling)
devenv.nix         service definitions for the shell
docker-compose.yml NapCat container (separate from devenv on purpose)
max.cabal          one library + one executable
src/OneBot/        OneBot 11 protocol: types, segments, events, actions, server
src/Max/           app config and the ping-pong handler
app/Main.hs        wires it all together
```

## First-time setup

### 1. Enter the dev shell

```sh
direnv allow            # or: nix develop --impure
```

The first invocation downloads GHC 9.12, HLS, Postgres 17 + pgvector, and a few CLIs (`websocat`, `jq`).

### 2. Configure secrets

```sh
cp .env.example .env
# edit .env: set NAPCAT_QQ to your small-account QQ number,
# and set MAX_ACCESS_TOKEN to a long random string.
```

### 3. Bring up Postgres

Inside the dev shell:

```sh
devenv up        # leaves it running in the foreground
```

Postgres listens on `127.0.0.1:5433`, database `max`, extension `vector` is created automatically.

### 4. Bring up NapCat and log in

The `docker-compose.yml` works as-is with either Docker Desktop or **OrbStack** — the `docker compose` CLI is identical. OrbStack is recommended on mac: faster startup, lighter, and its Rosetta path for amd64 images beats qemu.

In another terminal:

```sh
docker compose up -d napcat
```

Open <http://localhost:6099> in a browser, scan the QR with the QQ mobile app of the small account. The login state is persisted to `./.napcat/` (gitignored). The reverse-WS connection to `ws://host.docker.internal:8080/onebot` is preconfigured via env vars.

The `mlikiowa/napcat-docker:latest` image is multi-arch (linux/amd64 + linux/arm64), so it runs natively on Apple Silicon, Intel mac, and Linux alike — no Rosetta hop.

### 5. Run the bot

```sh
cabal run max-bot
```

You should see `max-bot listening on ws://0.0.0.0:8080/onebot`, and shortly after, an `action response` log line when NapCat connects.

### 6. Test in QQ

In any group the small account is a member of, send:

```
@bot ping
```

The bot should reply `@you pong`.

## Definition of done for Phase 1

- [x] `devenv up` brings up Postgres
- [x] `docker compose up napcat` and web-admin login work
- [x] `cabal run max-bot` accepts the reverse WS connection
- [x] `@bot ping` in a group → `pong` reply
- [x] heartbeat and lifecycle events are silently accepted
- [x] wrong `MAX_ACCESS_TOKEN` → connection rejected

## What's deliberately missing

| Concern | Where it lands |
|---|---|
| Reconnect / supervision | Phase 2 |
| Persisting messages, RAG | Phase 3-4 |
| `effectful` effect layering | Phase 5 |
| LLM client + tool calling | Phase 5 |
| Browser / container tools | Phase 6 |
| NixOS module + production deployment | Phase 8 |

## Debugging the protocol

Before running the Haskell bot you can confirm NapCat's reverse-WS shape with `websocat`:

```sh
websocat -s 8080
# then send a message in a group; NapCat will print the raw event JSON.
```

Pipe through `jq .` to make it readable.
