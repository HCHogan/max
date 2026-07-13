-- |
-- @docker@ CLI wrappers for the per-group browser container: the
-- pre-built @max-browser:latest@ image (see @browser-image/@) running
-- Playwright MCP in headless Streamable-HTTP mode.  Same shell-out
-- approach as "Max.Sandbox.Docker" (which we borrow 'runRm' / list
-- helpers from).
--
-- The container publishes its MCP port to an ephemeral @127.0.0.1@
-- host port; 'browserHostPort' reads the mapping back so the client
-- knows where to POST.
module Max.Browser.Docker
  ( runRunBrowser,
    browserHostPort,
    defaultBrowserImage,
    containerPort,
  )
where

import Control.Exception (IOException, try)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

-- | Our pre-built browser image (@browser-image/build.sh@ → this tag).
-- It bakes @playwright-mcp@ plus its exact matching Chromium in, so
-- container start needs no npm/npx/browser download.  Build it once on
-- the docker host before browsing works.
defaultBrowserImage :: Text
defaultBrowserImage = "max-browser:latest"

-- | Fixed in-container port the MCP server binds; published to a
-- random host port.
containerPort :: Int
containerPort = 8931

-- | @docker run -d --name NAME -p 127.0.0.1::CPORT IMAGE playwright-mcp
-- --headless --browser chromium --host 0.0.0.0 --port CPORT@.  Returns
-- the container id.  @playwright-mcp@ and its Chromium are baked into
-- the image; @--browser chromium@ selects the bundled browser (not the
-- 'chrome' channel, which isn't installed).
runRunBrowser ::
  -- | container name
  Text ->
  -- | image
  Text ->
  IO (Either Text Text)
runRunBrowser name image = do
  let cp = show containerPort
      args =
        [ "run",
          "-d",
          "--init",
          "--name",
          T.unpack name,
          -- Disable the server→client heartbeat.  In HTTP mode
          -- playwright-mcp pings the client after the first tools/call
          -- and closes the whole session when the ping can't be
          -- delivered within 5s — and it never can be delivered here,
          -- because pings ride the GET SSE stream, which this bot's
          -- request/response-only MCP client (Max.MCP.Client) never
          -- opens.  0 turns the heartbeat off; session GC is ours
          -- anyway (registry teardown on !clear / exit).
          "-e",
          "PLAYWRIGHT_MCP_PING_TIMEOUT_MS=0",
          "-p",
          "127.0.0.1::" <> cp,
          T.unpack image,
          "playwright-mcp",
          "--headless",
          "--browser",
          "chromium",
          "--host",
          "0.0.0.0",
          "--port",
          cp
        ]
  res <- try @IOException $ readProcessWithExitCode "docker" args ""
  pure $ case res of
    Left e -> Left ("docker run failed: " <> T.pack (show e))
    Right (ExitSuccess, out, _) -> Right (T.strip (T.pack out))
    Right (ExitFailure c, _, err) ->
      Left ("docker run exited " <> T.pack (show c) <> ": " <> T.strip (T.pack err))

-- | @docker port NAME CPORT/tcp@ → the host port the MCP endpoint is
-- reachable on (e.g. @32771@).  Docker prints @127.0.0.1:32771@ (or
-- @0.0.0.0:32771@); we take the trailing port.
browserHostPort :: Text -> IO (Either Text Int)
browserHostPort name = do
  res <-
    try @IOException $
      readProcessWithExitCode
        "docker"
        ["port", T.unpack name, show containerPort <> "/tcp"]
        ""
  pure $ case res of
    Left e -> Left ("docker port failed: " <> T.pack (show e))
    Right (ExitSuccess, out, _) ->
      case parsePort (T.pack out) of
        Just p -> Right p
        Nothing -> Left ("could not parse docker port output: " <> T.strip (T.pack out))
    Right (ExitFailure c, _, err) ->
      Left ("docker port exited " <> T.pack (show c) <> ": " <> T.strip (T.pack err))
  where
    parsePort out = case T.lines out of
      (l : _) -> case T.splitOn ":" (T.strip l) of
        parts@(_ : _) -> readMaybeInt (last parts)
        _ -> Nothing
      _ -> Nothing
    readMaybeInt t = case reads (T.unpack (T.strip t)) of
      [(n, "")] -> Just n
      _ -> Nothing
