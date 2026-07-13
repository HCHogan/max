# Pre-built image for max-bot's per-group browser containers (built by
# build.sh as max-browser:latest).  Max.Browser.Docker starts one
# container per group from this image running Playwright MCP in headless
# Streamable-HTTP mode.
#
# Why a custom image instead of `npx @playwright/mcp` on the stock
# Playwright image: @playwright/mcp@latest pins an *alpha* Playwright
# whose Chromium revision the stable `mcr.microsoft.com/playwright:*`
# images don't bundle.  We install MCP's own matching Chromium here at
# build time so container start needs no npm/npx/browser download and is
# version-consistent.  Rebuild when bumping the MCP pin.
FROM mcr.microsoft.com/playwright:v1.54.1-noble

# Install Playwright MCP globally, then install the exact Chromium its
# bundled Playwright expects (resolved from within the MCP package so
# the browser revision matches).  Browsers land in $PLAYWRIGHT_BROWSERS_PATH
# (/ms-playwright in this base image).
RUN npm install -g @playwright/mcp@latest \
 && cd "$(npm root -g)/@playwright/mcp" \
 && npx playwright install chromium

# The bot overrides CMD with the concrete --port/--host flags; this is a
# harmless default so the image is runnable on its own for debugging.
CMD ["mcp-server-playwright", "--headless", "--browser", "chromium", \
     "--host", "0.0.0.0", "--port", "8931"]
