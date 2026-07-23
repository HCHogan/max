-- |
-- Browser tools exposed to the agent, proxied to a per-group
-- camoufox-MCP server (see "Max.Browser.Registry").  The container is
-- started lazily on the first call and reused across dispatches.
--
-- == The snapshot → selector → act loop
--
-- Interaction is driven by @browser_snapshot@ (camoufox's
-- @browse_session_snapshot@): visible page text plus a list of
-- interactive elements, each carrying a generated CSS @selector@
-- (id-based where possible) with its role and accessible name.  The
-- model reads the snapshot, then targets elements by that selector in
-- @browser_click@ / @browser_type@.  No screenshots, no vision
-- required — but the whole toolset is only offered to
-- multimodal-capable profiles (gated in @app/Main.hs@).
--
-- == Sessions
--
-- All page state lives in a camoufox /browse session/.  The registry
-- records the group's live @sessionId@; every tool here injects it, so
-- the model never sees session plumbing.  @browser_navigate@ starts a
-- session on demand and transparently restarts one when camoufox
-- expired it (idle TTL, capped upstream at 15 min); the other tools
-- report the expiry and point the model back at @browser_navigate@.
module Max.Tools.Browser
  ( browserToolsFor,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Monad (void, when)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Max.Browser.Registry
  ( BrowserRegistry,
    brProxy,
    callBrowserTool,
    getCamoSession,
    setCamoSession,
  )
import Max.Effects.Tools (Tool (..))
import Max.MCP.Client (mcpTextContent)
import OneBot.Types (GroupId)

browserToolsFor :: IOE :> es => GroupId -> BrowserRegistry -> [Tool es]
browserToolsFor gid reg =
  [ navigateTool gid reg,
    viewZhihuTool gid reg,
    snapshotTool gid reg,
    clickTool gid reg,
    typeTool gid reg,
    pressKeyTool gid reg,
    waitForTool gid reg,
    scrollTool gid reg
  ]

--------------------------------------------------------------------------------
-- Session plumbing.

-- | Errors from camoufox that mean the browse session is gone (idle
-- TTL hit, server closed it) — the stored id is useless now.
camoSessionDead :: Text -> Bool
camoSessionDead err =
  any
    (`T.isInfixOf` err)
    [ "Unknown or closed session",
      "Session expired",
      "Session is closing or closed"
    ]

-- | Errors from camoufox's request guard, which /latches/: after one
-- blocked request (SSRF-suspect URL, or the session's 1024-request
-- budget running out) every further operation on the session rethrows
-- the same error forever.  Unlike 'camoSessionDead' the session is
-- still alive and still occupies a server slot, so recovery must
-- @browse_session_close@ it before starting a fresh one.
camoSessionWedged :: Text -> Bool
camoSessionWedged = ("Blocked unsafe browser request" `T.isInfixOf`)

-- | Forget the group's session; when it is wedged-but-alive, also
-- close it server-side to free the slot (best-effort).
dropSession :: BrowserRegistry -> GroupId -> Text -> Bool -> IO ()
dropSession reg gid sid closeIt = do
  setCamoSession reg gid Nothing
  when closeIt . void $
    callBrowserTool reg gid "browse_session_close" (object ["sessionId" .= sid])

-- | Start a fresh camoufox browse session and record its id.
startSession :: BrowserRegistry -> GroupId -> IO (Either Text Text)
startSession reg gid = do
  setCamoSession reg gid Nothing
  let startArgs = object (("humanize" .= True) : foldMap (\p -> ["proxy" .= p]) reg.brProxy)
  callBrowserTool reg gid "browse_session_start" startArgs >>= \case
    Left e -> pure (Left e)
    Right v -> case sessionIdOf v of
      Nothing ->
        pure (Left ("browse_session_start returned no sessionId: " <> T.take 200 (mcpTextContent v)))
      Just sid -> Right sid <$ setCamoSession reg gid (Just sid)

-- | Pull the @sessionId@ out of a @browse_session_start@ result:
-- prefer the MCP @structuredContent@, fall back to the JSON text block.
sessionIdOf :: Value -> Maybe Text
sessionIdOf v =
  parseMaybe structured v
    <|> (decodeStrict (TE.encodeUtf8 (mcpTextContent v)) >>= parseMaybe fromPayload)
  where
    structured = withObject "result" $ \o -> o .: "structuredContent" >>= fromPayload
    fromPayload :: Value -> Parser Text
    fromPayload = withObject "payload" (.: "sessionId")

-- | Run one @browse_session_*@ tool against the group's session,
-- injecting @sessionId@.  Requires an existing session; on a
-- session-death error the stored id is dropped and the model is told
-- to re-navigate.
withSession ::
  BrowserRegistry ->
  GroupId ->
  Text ->
  [(Key, Value)] ->
  IO (Either Text Value)
withSession reg gid mcpTool fields =
  getCamoSession reg gid >>= \case
    Nothing -> pure (Left "no page is open — call browser_navigate first")
    Just sid ->
      callBrowserTool reg gid mcpTool (withSid sid fields) >>= \case
        Left err
          | camoSessionWedged err -> do
              dropSession reg gid sid True
              pure (Left ("the browser blocked a request and the session was reset — call browser_navigate to reopen (" <> err <> ")"))
          | camoSessionDead err -> do
              dropSession reg gid sid False
              pure (Left "the browser session expired — call browser_navigate to reopen the page")
        r -> pure r

withSid :: Text -> [(Key, Value)] -> Value
withSid sid fields = object (("sessionId" .= sid) : fields)

-- | An MCP tool result flattened for the model.
asResult :: Either Text Value -> Either Text Value
asResult = fmap (\v -> object ["result" .= mcpTextContent v])

--------------------------------------------------------------------------------
-- Argument helpers (model args arrive as a JSON object).

argText :: Value -> Key -> Maybe Text
argText v k = parseMaybe (withObject "args" (.: k)) v

argBool :: Value -> Key -> Maybe Bool
argBool v k = parseMaybe (withObject "args" (.: k)) v

-- | Copy the given keys from the model's args into MCP argument
-- fields, skipping absent ones.
passThrough :: Value -> [Key] -> [(Key, Value)]
passThrough (Object o) keys = [(k, x) | k <- keys, Just x <- [KM.lookup k o]]
passThrough _ _ = []

--------------------------------------------------------------------------------
-- Schemas.

obj :: [(Key, Value)] -> [Text] -> Value
obj props required =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object props,
      "required" .= required
    ]

str :: Text -> Value
str desc = object ["type" .= ("string" :: Text), "description" .= desc]

boolP :: Text -> Value
boolP desc = object ["type" .= ("boolean" :: Text), "description" .= desc]

numP :: Text -> Value
numP desc = object ["type" .= ("number" :: Text), "description" .= desc]

enumP :: [Text] -> Text -> Value
enumP vals desc =
  object ["type" .= ("string" :: Text), "enum" .= vals, "description" .= desc]

--------------------------------------------------------------------------------
-- Tools.

navigateTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
navigateTool gid reg =
  Tool
    { toolName = "browser_navigate",
      toolDescription =
        "Open a URL in the group's stealth browser (camoufox). Starts the browser on \
        \first use and reopens it transparently if the session expired. Returns the \
        \page's visible text; call browser_snapshot for interactive elements.",
      toolSchema = obj [("url", str "Absolute URL to open, e.g. https://example.com")] ["url"],
      toolRun = \args -> liftIO $ do
        case argText args "url" of
          Nothing -> pure (Left "missing required argument: url")
          Just url -> asResult <$> navigateUrl reg gid url
    }

-- | Navigate the group's browser to a URL, starting (or transparently
-- replacing) the camoufox session as needed — the machinery behind
-- @browser_navigate@, shared with @view_zhihu@.
navigateUrl :: BrowserRegistry -> GroupId -> Text -> IO (Either Text Value)
navigateUrl reg gid url =
  getCamoSession reg gid >>= \case
    Nothing -> freshNavigate
    Just sid ->
      callBrowserTool reg gid "browse_session_navigate" (navArgs sid) >>= \case
        Left err
          | camoSessionWedged err -> dropSession reg gid sid True >> freshNavigate
          | camoSessionDead err -> dropSession reg gid sid False >> freshNavigate
        r -> pure r
  where
    freshNavigate =
      startSession reg gid
        >>= either (pure . Left) (\sid -> callBrowserTool reg gid "browse_session_navigate" (navArgs sid))
    navArgs sid = withSid sid ["url" .= url]

--------------------------------------------------------------------------------
-- view_zhihu

-- | One-call Zhihu reader for share cards.  Plain HTTP gets a 403
-- from Zhihu's edge, and even camoufox eats a challenge page on the
-- first visit of a fresh session — but the challenge sets cookies,
-- and reloading the same URL in the same session goes through
-- (verified: question / answer / zhuanlan pages all render).  So:
-- navigate, and when the response smells like the challenge
-- (non-200, or the slogan-only interstitial), wait and renavigate,
-- up to 'zhihuRetries' times.
viewZhihuTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
viewZhihuTool gid reg =
  Tool
    { toolName = "view_zhihu",
      toolDescription =
        "看一个知乎链接的内容：问题页、回答、专栏文章都行，分享卡片 [card:] 里的\
        \知乎链接直接传进来。用群的隐身浏览器打开并返回页面正文（知乎首访有一道\
        \验证，工具自动重试，稍慢是正常的）。返回后页面保持打开：想看更多回答/\
        \评论可以接着用 browser_scroll + browser_snapshot。",
      toolSchema =
        obj
          [("url", str "知乎链接（zhihu.com/question/…、…/answer/…、zhuanlan.zhihu.com/p/…）")]
          ["url"],
      toolRun = \args -> liftIO $ do
        case argText args "url" of
          Nothing -> pure (Left "missing required argument: url")
          Just url
            | not ("zhihu.com" `T.isInfixOf` url) ->
                pure (Left "不是知乎链接；其他网页用 browser_navigate 打开")
            | otherwise -> go zhihuRetries url
    }
  where
    go retries url =
      navigateUrl reg gid url >>= \case
        Left e -> pure (Left e)
        Right v -> case navPayload v of
          Just (status, txt)
            | looksLikeChallenge status txt && retries > 0 -> do
                threadDelay 2_500_000
                go (retries - 1) url
            | looksLikeChallenge status txt ->
                pure (Left ("知乎的验证页没绕过去（HTTP " <> T.pack (show status) <> "），稍后再试"))
            | otherwise ->
                pure . Right $
                  object
                    [ "url" .= url,
                      "text" .= T.take zhihuMaxChars txt,
                      "note" .= ("页面保持打开，想看更多可用 browser_scroll / browser_snapshot" :: Text)
                    ]
          -- Payload shape we don't recognise: hand the raw result
          -- over rather than guessing.
          Nothing -> pure (asResult (Right v))

    looksLikeChallenge status txt =
      status /= (200 :: Int)
        || ("让每一次点击都充满意义" `T.isInfixOf` txt && T.length txt < 400)

zhihuRetries :: Int
zhihuRetries = 2

zhihuMaxChars :: Int
zhihuMaxChars = 12000

-- | Pull @(status, text)@ out of a @browse_session_navigate@ result:
-- prefer MCP @structuredContent@, fall back to the JSON text block.
navPayload :: Value -> Maybe (Int, Text)
navPayload v =
  parseMaybe structured v
    <|> (decodeStrict (TE.encodeUtf8 (mcpTextContent v)) >>= parseMaybe fromPayload)
  where
    structured = withObject "result" $ \o -> o .: "structuredContent" >>= fromPayload
    fromPayload :: Value -> Parser (Int, Text)
    fromPayload = withObject "payload" $ \o -> (,) <$> o .: "status" <*> o .: "text"

snapshotTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
snapshotTool gid reg =
  Tool
    { toolName = "browser_snapshot",
      toolDescription =
        "Capture the current page: visible text plus interactive elements, each with a \
        \CSS 'selector' (and role/name) you pass to browser_click / browser_type. Call \
        \this after navigating or after any action that changes the page; selectors \
        \from an old snapshot may be stale.",
      toolSchema =
        obj
          [ ("selector", str "Optional CSS selector to limit the snapshot to one element."),
            ("maxElements", numP "Maximum interactive elements to return (default 100).")
          ]
          [],
      toolRun = \args ->
        liftIO $
          asResult
            <$> withSession reg gid "browse_session_snapshot" (passThrough args ["selector", "maxElements"])
    }

-- | Wrap one camoufox sequence action as a @browse_session_action@ call.
runAction :: BrowserRegistry -> GroupId -> [(Key, Value)] -> IO (Either Text Value)
runAction reg gid actionFields =
  withSession reg gid "browse_session_action" ["action" .= object actionFields]

clickTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
clickTool gid reg =
  Tool
    { toolName = "browser_click",
      toolDescription =
        "Click an element identified by a CSS selector from the latest browser_snapshot. \
        \Returns a fresh snapshot after the click.",
      toolSchema =
        obj [("selector", str "CSS selector of the element, from the latest snapshot.")] ["selector"],
      toolRun = \args -> liftIO $ case argText args "selector" of
        Nothing -> pure (Left "missing required argument: selector")
        Just sel ->
          asResult
            <$> runAction reg gid ["type" .= ("click" :: Text), "selector" .= sel, "clickMode" .= ("auto" :: Text)]
    }

typeTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
typeTool gid reg =
  Tool
    { toolName = "browser_type",
      toolDescription =
        "Fill text into an editable element identified by a CSS selector from the latest \
        \snapshot (replaces its current value). Set submit=true to press Enter afterwards.",
      toolSchema =
        obj
          [ ("selector", str "CSS selector of the field, from the latest snapshot."),
            ("text", str "Text to fill in."),
            ("submit", boolP "Press Enter after filling (default false).")
          ]
          ["selector", "text"],
      toolRun = \args -> liftIO $ case (argText args "selector", argText args "text") of
        (Just sel, Just txt) -> do
          filled <- runAction reg gid ["type" .= ("fill" :: Text), "selector" .= sel, "value" .= txt]
          asResult <$> case (filled, argBool args "submit") of
            (Right _, Just True) ->
              runAction reg gid ["type" .= ("press" :: Text), "selector" .= sel, "key" .= ("Enter" :: Text)]
            _ -> pure filled
        _ -> pure (Left "missing required arguments: selector, text")
    }

pressKeyTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
pressKeyTool gid reg =
  Tool
    { toolName = "browser_press_key",
      toolDescription =
        "Press a single key, e.g. Enter, ArrowDown, Escape — on a specific element \
        \(selector) or the currently focused one.",
      toolSchema =
        obj
          [ ("key", str "Key name, e.g. Enter or ArrowDown."),
            ("selector", str "Optional CSS selector to focus before pressing.")
          ]
          ["key"],
      toolRun = \args -> liftIO $ case argText args "key" of
        Nothing -> pure (Left "missing required argument: key")
        Just key ->
          asResult
            <$> runAction
              reg
              gid
              ( ["type" .= ("press" :: Text), "key" .= key]
                  <> maybe [] (\s -> ["selector" .= s]) (argText args "selector")
              )
    }

waitForTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
waitForTool gid reg =
  Tool
    { toolName = "browser_wait_for",
      toolDescription =
        "Wait for an element (CSS selector) to reach a state, or for the page to reach a \
        \load state. Give at least one of selector / loadState. Useful after an action \
        \that triggers async loading.",
      toolSchema =
        obj
          [ ("selector", str "CSS selector to wait on."),
            ("state", enumP ["attached", "detached", "visible", "hidden"] "Element state to wait for (default visible)."),
            ("loadState", enumP ["domcontentloaded", "load", "networkidle"] "Page load state to wait for."),
            ("timeout", numP "Timeout in milliseconds (100-60000).")
          ]
          [],
      toolRun = \args ->
        liftIO $
          asResult
            <$> runAction
              reg
              gid
              (("type" .= ("waitFor" :: Text)) : passThrough args ["selector", "state", "loadState", "timeout"])
    }

scrollTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
scrollTool gid reg =
  Tool
    { toolName = "browser_scroll",
      toolDescription =
        "Scroll the page (or an element) vertically/horizontally. Positive deltaY \
        \scrolls down (default 600 px). Returns a fresh snapshot afterwards.",
      toolSchema =
        obj
          [ ("deltaY", numP "Vertical scroll amount in px (negative scrolls up; default 600)."),
            ("deltaX", numP "Horizontal scroll amount in px."),
            ("selector", str "Optional CSS selector of a scrollable element.")
          ]
          [],
      toolRun = \args ->
        liftIO $
          asResult
            <$> runAction
              reg
              gid
              (("type" .= ("scroll" :: Text)) : passThrough args ["deltaY", "deltaX", "selector"])
    }
