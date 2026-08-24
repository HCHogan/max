-- |
-- Browser tools exposed to the agent.  A group reuses one lightweight Docker
-- host, while every turn/subagent receives an isolated MCP client and camoufox
-- browse session (see "Max.Browser.Registry").
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
-- records the turn's live @sessionId@; every tool here injects it, so
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
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Max.Browser.Error
  ( BrowserErrorKind (..),
    browserErrorKind,
    renderBrowserError,
  )
import Max.Browser.Registry
  ( BrowserRegistry,
    BrowserScope,
    browserScopeForDispatch,
    browserScopeForTurn,
    callBrowserTool,
    getCamoSession,
    setCamoSession,
    withBrowserSession,
  )
import Max.Effects.Tools (Tool (..))
import Max.MCP.Client (mcpTextContent)
import Max.ToolContext (ToolContext, toolCanonicalId, toolGroupId, toolTurnOutputContext)
import Max.Tools.Schema (boolParam, enumParam, numberParam, stringParam, toolObject)
import Max.Turn.Types (AgentTurnRef (atrTurnId), turnOutputAgentTurn)

browserToolsFor :: (IOE :> es) => ToolContext -> BrowserRegistry -> Maybe Text -> [Tool es]
browserToolsFor context reg proxy =
  [ navigateTool scope reg proxy,
    viewZhihuTool scope reg proxy,
    snapshotTool scope reg,
    clickTool scope reg,
    typeTool scope reg,
    pressKeyTool scope reg,
    waitForTool scope reg,
    scrollTool scope reg
  ]
  where
    scope =
      maybe
        (browserScopeForDispatch (toolGroupId context) (toolCanonicalId context))
        (browserScopeForTurn (toolGroupId context) . (.atrTurnId) . turnOutputAgentTurn)
        (toolTurnOutputContext context)

--------------------------------------------------------------------------------
-- Session plumbing.

-- | Forget the turn's session; when it is wedged-but-alive, also
-- close it server-side to free the slot (best-effort).
dropSession :: BrowserRegistry -> BrowserScope -> Text -> Bool -> IO ()
dropSession reg scope sid closeIt = do
  setCamoSession reg scope Nothing
  when closeIt . void $
    callBrowserTool reg scope "browse_session_close" (object ["sessionId" .= sid])

-- | Start a fresh camoufox browse session and record its id.
startSession :: BrowserRegistry -> BrowserScope -> Maybe Text -> IO (Either Text Text)
startSession reg scope proxy = do
  setCamoSession reg scope Nothing
  let startArgs = object (("humanize" .= True) : foldMap (\p -> ["proxy" .= p]) proxy)
  callBrowserTool reg scope "browse_session_start" startArgs >>= \case
    Left e -> pure (Left (renderBrowserError e))
    Right v -> case sessionIdOf v of
      Nothing ->
        pure (Left ("browse_session_start returned no sessionId: " <> T.take 200 (mcpTextContent v)))
      Just sid -> Right sid <$ setCamoSession reg scope (Just sid)

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

-- | Run one @browse_session_*@ tool against the turn's session,
-- injecting @sessionId@.  Requires an existing session; on a
-- session-death error the stored id is dropped and the model is told
-- to re-navigate.
withSession ::
  BrowserRegistry ->
  BrowserScope ->
  Text ->
  [(Key, Value)] ->
  IO (Either Text Value)
withSession reg scope mcpTool fields =
  withBrowserSession reg scope $
    getCamoSession reg scope >>= \case
      Nothing -> pure (Left "no page is open — call browser_navigate first")
      Just sid ->
        callBrowserTool reg scope mcpTool (withSid sid fields) >>= \case
          Left err -> case browserErrorKind err of
            BrowserSessionBlocked -> do
              dropSession reg scope sid True
              pure . Left $
                "the browser blocked a request and the session was reset — call browser_navigate to reopen ("
                  <> renderBrowserError err
                  <> ")"
            BrowserSessionGone -> do
              dropSession reg scope sid False
              pure (Left "the browser session expired — call browser_navigate to reopen the page")
            BrowserCallFailed -> pure (Left (renderBrowserError err))
          Right value -> pure (Right value)

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
-- Tools.

navigateTool :: (IOE :> es) => BrowserScope -> BrowserRegistry -> Maybe Text -> Tool es
navigateTool scope reg proxy =
  Tool
    { toolName = "browser_navigate",
      toolDescription =
        "Open a URL in this turn's isolated stealth browser (camoufox). Starts it on \
        \first use and reopens it transparently if the session expired. Returns the \
        \page's visible text; call browser_snapshot for interactive elements.",
      toolSchema = toolObject [("url", stringParam "Absolute URL to open, e.g. https://example.com")] ["url"],
      toolRun = \args -> liftIO $ do
        case argText args "url" of
          Nothing -> pure (Left "missing required argument: url")
          Just url -> asResult <$> navigateUrl reg scope proxy url
    }

-- | Navigate the turn's browser to a URL, starting (or transparently
-- replacing) the camoufox session as needed — the machinery behind
-- @browser_navigate@, shared with @view_zhihu@.
navigateUrl :: BrowserRegistry -> BrowserScope -> Maybe Text -> Text -> IO (Either Text Value)
navigateUrl reg scope proxy url =
  withBrowserSession reg scope $
    getCamoSession reg scope >>= \case
      Nothing -> freshNavigate
      Just sid ->
        callBrowserTool reg scope "browse_session_navigate" (navArgs sid) >>= \case
          Left err -> case browserErrorKind err of
            BrowserSessionBlocked -> dropSession reg scope sid True >> freshNavigate
            BrowserSessionGone -> dropSession reg scope sid False >> freshNavigate
            BrowserCallFailed -> pure (Left (renderBrowserError err))
          Right value -> pure (Right value)
  where
    freshNavigate =
      startSession reg scope proxy
        >>= either
          (pure . Left)
          (\sid -> first renderBrowserError <$> callBrowserTool reg scope "browse_session_navigate" (navArgs sid))
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
viewZhihuTool :: (IOE :> es) => BrowserScope -> BrowserRegistry -> Maybe Text -> Tool es
viewZhihuTool scope reg proxy =
  Tool
    { toolName = "view_zhihu",
      toolDescription =
        "看一个知乎链接的内容（问题页、回答、专栏文章；分享卡片 [card:] 里的\
        \知乎链接直接传）。自动过知乎的首访验证，稍慢是正常的；翻页看更多的\
        \流程见 use_skill 的 web 手册。",
      toolSchema =
        toolObject
          [("url", stringParam "知乎链接（zhihu.com/question/…、…/answer/…、zhuanlan.zhihu.com/p/…）")]
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
      navigateUrl reg scope proxy url >>= \case
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

snapshotTool :: (IOE :> es) => BrowserScope -> BrowserRegistry -> Tool es
snapshotTool scope reg =
  Tool
    { toolName = "browser_snapshot",
      toolDescription =
        "Capture the current page: visible text plus interactive elements, each with a \
        \CSS 'selector' (and role/name) you pass to browser_click / browser_type. Call \
        \this after navigating or after any action that changes the page; selectors \
        \from an old snapshot may be stale.",
      toolSchema =
        toolObject
          [ ("selector", stringParam "Optional CSS selector to limit the snapshot to one element."),
            ("maxElements", numberParam "Maximum interactive elements to return (default 100).")
          ]
          [],
      toolRun = \args ->
        liftIO $
          asResult
            <$> withSession reg scope "browse_session_snapshot" (passThrough args ["selector", "maxElements"])
    }

-- | Wrap one camoufox sequence action as a @browse_session_action@ call.
runAction :: BrowserRegistry -> BrowserScope -> [(Key, Value)] -> IO (Either Text Value)
runAction reg scope actionFields =
  withSession reg scope "browse_session_action" ["action" .= object actionFields]

clickTool :: (IOE :> es) => BrowserScope -> BrowserRegistry -> Tool es
clickTool scope reg =
  Tool
    { toolName = "browser_click",
      toolDescription =
        "Click an element identified by a CSS selector from the latest browser_snapshot. \
        \Returns a fresh snapshot after the click.",
      toolSchema =
        toolObject [("selector", stringParam "CSS selector of the element, from the latest snapshot.")] ["selector"],
      toolRun = \args -> liftIO $ case argText args "selector" of
        Nothing -> pure (Left "missing required argument: selector")
        Just sel ->
          asResult
            <$> runAction reg scope ["type" .= ("click" :: Text), "selector" .= sel, "clickMode" .= ("auto" :: Text)]
    }

typeTool :: (IOE :> es) => BrowserScope -> BrowserRegistry -> Tool es
typeTool scope reg =
  Tool
    { toolName = "browser_type",
      toolDescription =
        "Fill text into an editable element identified by a CSS selector from the latest \
        \snapshot (replaces its current value). Set submit=true to press Enter afterwards.",
      toolSchema =
        toolObject
          [ ("selector", stringParam "CSS selector of the field, from the latest snapshot."),
            ("text", stringParam "Text to fill in."),
            ("submit", boolParam "Press Enter after filling (default false).")
          ]
          ["selector", "text"],
      toolRun = \args -> liftIO $ case (argText args "selector", argText args "text") of
        (Just sel, Just txt) -> do
          filled <- runAction reg scope ["type" .= ("fill" :: Text), "selector" .= sel, "value" .= txt]
          asResult <$> case (filled, argBool args "submit") of
            (Right _, Just True) ->
              runAction reg scope ["type" .= ("press" :: Text), "selector" .= sel, "key" .= ("Enter" :: Text)]
            _ -> pure filled
        _ -> pure (Left "missing required arguments: selector, text")
    }

pressKeyTool :: (IOE :> es) => BrowserScope -> BrowserRegistry -> Tool es
pressKeyTool scope reg =
  Tool
    { toolName = "browser_press_key",
      toolDescription =
        "Press a single key, e.g. Enter, ArrowDown, Escape — on a specific element \
        \(selector) or the currently focused one.",
      toolSchema =
        toolObject
          [ ("key", stringParam "Key name, e.g. Enter or ArrowDown."),
            ("selector", stringParam "Optional CSS selector to focus before pressing.")
          ]
          ["key"],
      toolRun = \args -> liftIO $ case argText args "key" of
        Nothing -> pure (Left "missing required argument: key")
        Just key ->
          asResult
            <$> runAction
              reg
              scope
              ( ["type" .= ("press" :: Text), "key" .= key]
                  <> maybe [] (\s -> ["selector" .= s]) (argText args "selector")
              )
    }

waitForTool :: (IOE :> es) => BrowserScope -> BrowserRegistry -> Tool es
waitForTool scope reg =
  Tool
    { toolName = "browser_wait_for",
      toolDescription =
        "Wait for an element (CSS selector) to reach a state, or for the page to reach a \
        \load state. Give at least one of selector / loadState. Useful after an action \
        \that triggers async loading.",
      toolSchema =
        toolObject
          [ ("selector", stringParam "CSS selector to wait on."),
            ("state", enumParam ["attached", "detached", "visible", "hidden"] "Element state to wait for (default visible)."),
            ("loadState", enumParam ["domcontentloaded", "load", "networkidle"] "Page load state to wait for."),
            ("timeout", numberParam "Timeout in milliseconds (100-60000).")
          ]
          [],
      toolRun = \args ->
        liftIO $
          asResult
            <$> runAction
              reg
              scope
              (("type" .= ("waitFor" :: Text)) : passThrough args ["selector", "state", "loadState", "timeout"])
    }

scrollTool :: (IOE :> es) => BrowserScope -> BrowserRegistry -> Tool es
scrollTool scope reg =
  Tool
    { toolName = "browser_scroll",
      toolDescription =
        "Scroll the page (or an element) vertically/horizontally. Positive deltaY \
        \scrolls down (default 600 px). Returns a fresh snapshot afterwards.",
      toolSchema =
        toolObject
          [ ("deltaY", numberParam "Vertical scroll amount in px (negative scrolls up; default 600)."),
            ("deltaX", numberParam "Horizontal scroll amount in px."),
            ("selector", stringParam "Optional CSS selector of a scrollable element.")
          ]
          [],
      toolRun = \args ->
        liftIO $
          asResult
            <$> runAction
              reg
              scope
              (("type" .= ("scroll" :: Text)) : passThrough args ["deltaY", "deltaX", "selector"])
    }
