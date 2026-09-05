# Pre-built image for max-bot's per-group browser containers (built by
# build.sh as max-browser:latest).  Max.Browser.Docker starts one
# container per group from this image running camoufox-mcp (a stealth
# Firefox fork driven over MCP) behind supergateway, which bridges the
# server's stdio-only transport to the Streamable HTTP that
# Max.MCP.Client speaks.
#
# Why supergateway --stateful: camoufox-mcp keeps its browse_session_*
# state (the live browser) inside its process, and stateful mode gives
# each MCP session one long-lived child process.  Stateless mode spawns
# a fresh child per HTTP request, which would drop the browser between
# calls.  No --sessionTimeout on purpose: idle expiry killed sessions
# out from under the bot in the playwright-mcp era, and container
# Max's workspace manager controls retention and refreshes retained sessions.
# CAMOUFOX_MCP_SESSION_TTL_MS is a leak watchdog if that manager disappears.
#
# Built from the camoufox-mcp git source with its own package-lock
# (mirroring upstream's Dockerfile) rather than `npm install -g`: the
# transitive dep `impit` has an `npx only-allow pnpm` preinstall that
# breaks global npm installs.  The pnpm-flavoured npm_config_user_agent
# on the install steps placates only-allow while still running install
# scripts (impit needs its prebuilt-binary fetch).
#
# The camoufox browser binary (~663MB compressed) is a fixed-output Nix
# input supplied as camoufox-browser.zip in the build context.  Keeping
# that large, immutable download outside an ephemeral Docker RUN makes
# failed/repeated nixos-rebuilds reuse the verified Nix store object.
# The source revision is pinned because the small structured-error patch below
# is part of our protocol contract.  Bump CAMOUFOX_MCP_REF and refresh the
# patch deliberately when upgrading upstream.

FROM node:22-bookworm AS source

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 build-essential ca-certificates curl patch unzip \
    && rm -rf /var/lib/apt/lists/*

ARG CAMOUFOX_MCP_REF=e5057f3bcf5bae9b2bc5d9c43972e89b6519ee9c
RUN mkdir -p /app \
 && curl --fail --location --http1.1 \
      --retry 5 --retry-all-errors --retry-delay 3 --retry-max-time 600 \
      --connect-timeout 15 --max-time 180 \
      --output /tmp/camoufox-mcp.tar.gz \
      "https://codeload.github.com/whit3rabbit/camoufox-mcp/tar.gz/${CAMOUFOX_MCP_REF}" \
 && tar -xzf /tmp/camoufox-mcp.tar.gz --strip-components=1 -C /app \
 && rm /tmp/camoufox-mcp.tar.gz
WORKDIR /app

COPY camoufox-structured-errors.patch /tmp/camoufox-structured-errors.patch
RUN patch --batch --forward -p1 --input=/tmp/camoufox-structured-errors.patch

COPY camoufox-workspaces.patch /tmp/camoufox-workspaces.patch
RUN patch --batch --forward -p1 --input=/tmp/camoufox-workspaces.patch
COPY workspace-lease.ts workspace-tools.ts /app/src/
COPY workspace-lease.test.mjs /tmp/workspace-lease.test.mjs

FROM source AS builder

RUN npm_config_user_agent="pnpm/10.0.0 npm/10.9.8 node/v22.0.0 linux x64" npm ci \
 && npm run build \
 && node /tmp/workspace-lease.test.mjs /app/dist/workspace-lease.js \
 && npm prune --omit=dev

# camoufox-js considers any existing addon directory complete, even when a
# failed download left it without manifest.json.  Validate the actual marker
# before reusing it so a transient failure is recoverable.
RUN sed -i 's/if (fs.existsSync(addonPath)) {/if (fs.existsSync(join(addonPath, "manifest.json"))) {/' node_modules/camoufox-js/dist/addons.js \
 && grep -q 'existsSync(join(addonPath, "manifest.json"))' node_modules/camoufox-js/dist/addons.js

# COPY comes after the npm build so an asset-only upgrade keeps that
# comparatively expensive layer cached.  The browser, default addon, and
# GeoIP database are fixed-output Nix inputs: a production session must not
# depend on Mozilla/GitHub being reachable during browser launch.
ARG CAMOUFOX_BROWSER_VERSION
ARG CAMOUFOX_BROWSER_RELEASE
COPY camoufox-browser.zip ublock-origin.xpi GeoLite2-City.mmdb /tmp/
RUN test -n "${CAMOUFOX_BROWSER_VERSION}" \
 && test -n "${CAMOUFOX_BROWSER_RELEASE}" \
 && mkdir -p /root/.cache/camoufox/addons/UBO \
 && unzip -q /tmp/camoufox-browser.zip -d /root/.cache/camoufox \
 && unzip -q /tmp/ublock-origin.xpi -d /root/.cache/camoufox/addons/UBO \
 && test -s /root/.cache/camoufox/addons/UBO/manifest.json \
 && install -m 0644 /tmp/GeoLite2-City.mmdb /root/.cache/camoufox/GeoLite2-City.mmdb \
 && printf '{"version":"%s","release":"%s"}\n' \
      "${CAMOUFOX_BROWSER_VERSION}" "${CAMOUFOX_BROWSER_RELEASE}" \
      > /root/.cache/camoufox/version.json \
 && chmod -R a+rX /root/.cache/camoufox \
 && rm /tmp/camoufox-browser.zip /tmp/ublock-origin.xpi /tmp/GeoLite2-City.mmdb

# The SSRF guard resolves every request host through container DNS and
# fails closed, which breaks behind censored DNS: github's telemetry
# domain returns NXDOMAIN (navigation aborted + session latched), and
# google domains "resolve" to injected garbage that trips the
# private/reserved check.  Patch in an env escape hatch that skips only
# the resolve-and-inspect step — the string-level checks (literal
# private IPs, localhost names) stay.  With a proxy configured the
# domain is resolved remotely by the proxy anyway.  The grep fails the
# build if upstream reshapes the code and the sed stops matching.
RUN sed -i 's/if (!needsDnsCheck) {/if (!needsDnsCheck || process.env.CAMOUFOX_MCP_SKIP_DNS_CHECK === "1") {/' dist/policy.js \
 && grep -q 'CAMOUFOX_MCP_SKIP_DNS_CHECK' dist/policy.js

FROM node:22-bookworm-slim

# Firefox/camoufox runtime libraries + xvfb (camoufox-mcp's own image
# runs the server under a virtual display; headful-under-Xvfb is part
# of the anti-detection story).
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb xauth \
    libgtk-3-0 libx11-xcb1 libxfixes3 libxrandr2 libxtst6 libx11-6 libxcomposite1 \
    libasound2 libdbus-glib-1-2 libpci3 libxss1 libnss3 libatk1.0-0 \
    libatk-bridge2.0-0 libcups2 libdrm2 libgbm1 libatspi2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Part of the transport contract; an upstream "latest" release must not
# silently change an otherwise content-addressed image build.
RUN npm install -g supergateway@3.4.3

# Run as non-root (mirrors upstream's image; Firefox is happier not
# running as root).
RUN useradd -m -u 1001 camoufox
USER camoufox
WORKDIR /home/camoufox/app

COPY --from=builder --chown=camoufox:camoufox /app/package.json ./
COPY --from=builder --chown=camoufox:camoufox /app/node_modules ./node_modules
COPY --from=builder --chown=camoufox:camoufox /app/dist ./dist
COPY --from=builder --chown=camoufox:camoufox /root/.cache/camoufox /home/camoufox/.cache/camoufox

EXPOSE 8931

# supergateway bridges: POST /mcp (Streamable HTTP, stateful sessions)
# <-> one xvfb-wrapped camoufox-mcp child per MCP session.  The bot's
# docker run publishes 8931 to an ephemeral loopback port.
CMD ["supergateway", \
     "--logLevel", "none", \
     "--stateful", \
     "--stdio", "xvfb-run -a --server-args='-screen 0 1280x1024x24' node /home/camoufox/app/dist/index.js", \
     "--outputTransport", "streamableHttp", \
     "--streamableHttpPath", "/mcp", \
     "--port", "8931"]
