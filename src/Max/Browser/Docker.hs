-- |
-- @docker@ CLI wrappers for the per-group browser container: the
-- pre-built @max-browser:latest@ image (see @browser-image/@) running
-- camoufox-mcp behind a supergateway stdio→Streamable-HTTP bridge.
-- Same shell-out approach as "Max.Sandbox.Docker" (which we borrow
-- 'runRm' / list helpers from).
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
import Data.List (unsnoc)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

-- | Our pre-built browser image (@browser-image/build.sh@ → this tag).
-- It bakes @camoufox-mcp-server@, @supergateway@ and the camoufox
-- browser binary in, so container start needs no npm/npx/browser
-- download.  Build it once on the docker host before browsing works.
defaultBrowserImage :: Text
defaultBrowserImage = "max-browser:latest"

-- | Fixed in-container port supergateway binds; published to a random
-- host port.
containerPort :: Int
containerPort = 8931

-- | @docker run -d --name NAME -p 127.0.0.1::CPORT IMAGE@.  Returns
-- the container id.  The image's CMD runs supergateway bridging
-- camoufox-mcp's stdio to Streamable HTTP on 'containerPort', so no
-- command override is needed here.
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
          -- Stretch camoufox-mcp's browse-session idle TTL to its
          -- 15-minute ceiling (default 10) — the group's page state
          -- lives in that session, and every expiry forces the model
          -- to re-navigate from scratch.
          "-e",
          "CAMOUFOX_MCP_SESSION_TTL_MS=900000",
          -- Headroom over the default of 1: recovery from a wedged
          -- session (request-guard latch) closes the old one before
          -- starting fresh, but if that close is ever lost, the TTL
          -- reaps the leak — meanwhile new sessions must still fit.
          "-e",
          "CAMOUFOX_MCP_MAX_SESSIONS=4",
          -- Skip the request guard's local resolve-and-inspect (image
          -- patch, see browser-image/Dockerfile): container DNS is
          -- censored here, so resolution failures / poisoned answers
          -- were latching sessions on ordinary pages.  String-level
          -- checks (literal private IPs, localhost names) still apply.
          "-e",
          "CAMOUFOX_MCP_SKIP_DNS_CHECK=1",
          -- Make a host-side proxy (browser.proxy in max.yaml as
          -- http://host.docker.internal:PORT) reachable on engines
          -- without built-in host.docker.internal (Linux).
          "--add-host",
          "host.docker.internal:host-gateway",
          "-p",
          "127.0.0.1::" <> cp,
          T.unpack image
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
    parsePort out = do
      line <- listToMaybe (T.lines out)
      (_, port) <- unsnoc (T.splitOn ":" (T.strip line))
      readMaybe (T.unpack (T.strip port))
