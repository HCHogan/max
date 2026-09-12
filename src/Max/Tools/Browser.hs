-- | One action-based browser tool and the dedicated Zhihu reader. Session IDs
-- and launch options are host-owned; uncertain operations are never replayed.
module Max.Tools.Browser
  ( browserToolsAt,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Monad (void, when)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Bifunctor (first)
import Data.Maybe (fromMaybe)
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
    browserScopeIsTask,
    callBrowserTool,
    getCamoSession,
    setCamoSession,
    takeBrowserRestore,
    withBrowserSession,
  )
import Max.Browser.View
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, canQueueInlineMediaOnce, queueInlineMediaOnce)
import Max.Effects.Tools (Tool (..))
import Max.MCP.Client (mcpTextContent)
import Max.Tools.Schema (boundedIntegerParam, enumParam, numberParam, stringParam, toolObject)

browserToolsAt :: (IOE :> es, ToolOutput :> es) => BrowserScope -> BrowserRegistry -> Maybe Text -> [Tool es]
browserToolsAt scope reg proxy =
  [browserTool scope reg proxy, viewZhihuTool scope reg proxy]

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
  restored <- takeBrowserRestore reg scope
  let storage = restored >>= parseMaybe (withObject "checkpoint" (.: "storage"))
      startArgs = object (("humanize" .= True) : foldMap (\p -> ["proxy" .= p]) proxy <> foldMap (\saved -> ["storage" .= (saved :: Value)]) storage)
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
      Nothing -> pure (Left "no page is open — call browser action=open first")
      Just sid ->
        callBrowserTool reg scope mcpTool (withSid sid fields) >>= \case
          Left err -> case browserErrorKind err of
            BrowserSessionBlocked -> do
              dropSession reg scope sid True
              pure . Left $
                "the browser blocked a request and the session was reset — call browser action=open to reopen ("
                  <> renderBrowserError err
                  <> ")"
            BrowserTransportLost -> pure (Left (renderBrowserError err))
            BrowserSessionGone -> do
              dropSession reg scope sid False
              pure (Left "the browser session expired — call browser action=open to reopen the page")
            BrowserCallFailed -> pure (Left (renderBrowserError err))
          Right value -> pure (Right value)

withSid :: Text -> [(Key, Value)] -> Value
withSid sid fields = object (("sessionId" .= sid) : fields)

--------------------------------------------------------------------------------
-- Argument helpers (model args arrive as a JSON object).

argText :: Value -> Key -> Maybe Text
argText v k = parseMaybe (withObject "args" (.: k)) v

-- | Copy the given keys from the model's args into MCP argument
-- fields, skipping absent ones.
passThrough :: Value -> [Key] -> [(Key, Value)]
passThrough (Object o) keys = [(k, x) | k <- keys, Just x <- [KM.lookup k o]]
passThrough _ _ = []

--------------------------------------------------------------------------------
-- Tools.

browserTool :: (IOE :> es, ToolOutput :> es) => BrowserScope -> BrowserRegistry -> Maybe Text -> Tool es
browserTool scope reg proxy =
  Tool
    { toolName = "browser",
      toolDescription =
        "Use this isolated stealth browser through action=open, snapshot, then selector-based actions. "
          <> "Every result is bounded text with page identity, position and notes. "
          <> "Use the latest selectors; navigation makes old selectors stale. "
          <> "A transport loss clears the page: open again, never repeat an uncertain interaction. "
          <> "evaluate is available only in a browser task. See use_skill web.",
      toolSchema =
        toolObject
          [ ("action", enumParam ["open", "snapshot", "click", "fill", "type", "press", "hover", "select", "scroll", "wait_for", "evaluate", "read", "find", "links", "forms", "screenshot", "dialog", "collect"] "Browser operation."),
            ("url", stringParam "Absolute HTTP(S) URL for open."),
            ("selector", stringParam "CSS selector from the latest snapshot; required for click/fill/type/hover/select."),
            ("frame", stringParam "Optional iframe CSS selector; element selectors resolve inside this frame."),
            ("text", stringParam "Text for fill (replace) or type (append keystrokes)."),
            ("value", object ["anyOf" .= [object ["type" .= ("string" :: Text)], object ["type" .= ("array" :: Text), "items" .= object ["type" .= ("string" :: Text)]]], "description" .= ("Option value(s) for select." :: Text)]),
            ("key", stringParam "Key for press, e.g. Enter or Escape."),
            ("delay", boundedIntegerParam 0 1000 0),
            ("deltaY", numberParam "Scroll distance, default 600 px; negative scrolls up."),
            ("deltaX", numberParam "Horizontal scroll distance."),
            ("state", enumParam ["attached", "detached", "visible", "hidden"] "Element state for wait_for."),
            ("loadState", enumParam ["domcontentloaded", "load", "networkidle"] "Readiness state for wait_for."),
            ("timeout", boundedIntegerParam 100 60000 10000),
            ("mode", enumParam ["text", "outline"] "read mode, default article text."),
            ("query", stringParam "Text to locate with find."),
            ("response", enumParam ["accept", "dismiss"] "One-shot answer for the next dialog, default dismiss."),
            ("promptText", stringParam "Text for accepting the next prompt dialog."),
            ("maxScrolls", boundedIntegerParam 1 20 5),
            ("waitMs", boundedIntegerParam 0 2000 250),
            ("expression", stringParam "JavaScript expression for evaluate; task sessions only."),
            ("maxChars", object ["type" .= ("integer" :: Text), "minimum" .= (512 :: Int), "maximum" .= (30000 :: Int), "description" .= ("Total result character budget including metadata. Default 6000 for open/snapshot, 1500 after actions." :: Text)]),
            ("maxElements", object ["type" .= ("integer" :: Text), "minimum" .= (1 :: Int), "maximum" .= (200 :: Int), "description" .= ("Default 40 for snapshot, 20 after an action." :: Text)])
          ]
          ["action"],
      toolRun = \args -> do
        canAttach <- canQueueInlineMediaOnce "browser.screenshot"
        let action = fromMaybe "" (argText args "action")
            budget = browserBudget action args
            limits = ["maxChars" .= budget.maxChars, "maxElements" .= budget.maxElements]
            required = case action of
              "open" -> ["url"]
              "click" -> ["selector"]
              "hover" -> ["selector"]
              "fill" -> ["selector", "text"]
              "type" -> ["selector", "text"]
              "select" -> ["selector", "value"]
              "press" -> ["key"]
              "evaluate" -> ["expression"]
              "find" -> ["query"]
              _ -> []
            missing = [key | key <- required, null (passThrough args [key])]
        result <-
          liftIO $
            if not (null missing)
              then pure (Left "missing required arguments for browser action")
              else case action of
                "open" -> navigateUrlWith reg scope proxy (fromMaybe "" (argText args "url")) (limits <> passThrough args ["timeout", "selector"])
                "snapshot" -> withSession reg scope "browse_session_snapshot" (limits <> passThrough args ["selector", "frame"])
                "screenshot"
                  | not canAttach ->
                      fmap (setScreenshotNote "screenshot not attached: this turn's screenshot or attachment quota is exhausted") <$> withSession reg scope "browse_session_snapshot" limits
                _
                  | action `elem` ["read", "find", "links", "forms", "screenshot", "dialog", "collect"] ->
                      withSession reg scope "browse_session_inspect" (("action" .= action) : limits <> passThrough args ["selector", "frame", "mode", "query", "response", "promptText", "maxScrolls", "waitMs", "timeout"])
                "evaluate" | not (browserScopeIsTask scope) -> pure (Left "evaluate requires a browser task; use task_start profile=browser")
                "wait_for" | null (passThrough args ["selector", "loadState"]) -> pure (Left "wait_for requires selector or loadState")
                _
                  | action `elem` ["click", "fill", "type", "press", "hover", "select", "scroll", "wait_for", "evaluate"] ->
                      let actionType = if action == "wait_for" then "waitFor" else action
                          fields =
                            ["type" .= actionType]
                              <> passThrough args ["selector", "frame", "key", "delay", "deltaY", "deltaX", "state", "loadState", "timeout", "expression"]
                              <> (if action == "fill" then ["value" .= argText args "text"] else passThrough args ["text", "value"])
                              <> ["maxChars" .= budget.maxChars | action == "evaluate"]
                       in withSession reg scope "browse_session_action" (("action" .= object fields) : limits)
                _ -> pure (Left "unknown browser action")
        withImage <- case result of
          Left err -> pure (Left err)
          Right value -> Right <$> attachBrowserScreenshot reg scope budget action canAttach value
        pure (first (browserFailureView budget action) (browserView budget action <$> withImage))
    }

-- The media queue is scoped to the actual Agent turn, so task generations and
-- rebuilt adapters cannot reset the one-screenshot budget.
attachBrowserScreenshot :: (IOE :> es, ToolOutput :> es) => BrowserRegistry -> BrowserScope -> BrowserBudget -> Text -> Bool -> Value -> Eff es Value
attachBrowserScreenshot reg scope budget action available value
  | not (browserNeedsScreenshot action value) = pure value
  | not available = pure (setScreenshotNote "screenshot not attached: this turn's screenshot or attachment quota is exhausted" value)
  | otherwise = do
      captured <-
        if action == "screenshot"
          then pure (Right value)
          else liftIO $ withSession reg scope "browse_session_inspect" ["action" .= ("screenshot" :: Text), "maxChars" .= budget.maxChars, "maxElements" .= budget.maxElements]
      case captured of
        Left err -> pure (setScreenshotNote ("screenshot unavailable: " <> T.take 200 err) value)
        Right imageResult -> case imageOf imageResult of
          Nothing -> pure (setScreenshotNote "screenshot unavailable: no image returned" value)
          Just dataUrl -> do
            queued <- queueInlineMediaOnce "browser.screenshot" (InlineMedia "browser viewport screenshot" dataUrl)
            pure (setScreenshotNote (if queued then "viewport screenshot attached" else "screenshot not attached: turn attachment quota exhausted") (mergeBrowserNotes imageResult value))
  where
    imageOf raw = do
      items <- parseMaybe (withObject "MCP result" (.: "content")) raw
      case ["data:" <> mime <> ";base64," <> bytes | item <- items, Just (kind, mime, bytes) <- [parseMaybe imageBlock item], kind == ("image" :: Text), mime `elem` ["image/jpeg", "image/png"], T.length bytes <= 2800000] of
        firstImage : _ -> Just firstImage
        [] -> Nothing
    imageBlock = withObject "image block" $ \o -> (,,) <$> o .: "type" <*> o .: "mimeType" <*> o .: "data"

mergeBrowserNotes :: Value -> Value -> Value
mergeBrowserNotes extra original = case browserPayload original of
  Object fields ->
    let notes payload = fromMaybe [] (parseMaybe (withObject "browser notes" (.: "notes")) (browserPayload payload)) :: [Value]
        combined = notes original <> [note | note <- notes extra, note `notElem` notes original]
     in object ["structuredContent" .= Object (KM.insert "notes" (toJSON combined) fields)]
  _ -> original

setScreenshotNote :: Text -> Value -> Value
setScreenshotNote note value = case browserPayload value of
  Object fields -> object ["structuredContent" .= Object (KM.insert "screenshotNote" (String note) fields)]
  _ -> value

-- | Navigate the turn's browser to a URL, starting (or transparently
-- replacing) the camoufox session as needed — the machinery behind
-- @browser action=open@, shared with @view_zhihu@.
navigateUrl :: BrowserRegistry -> BrowserScope -> Maybe Text -> Text -> IO (Either Text Value)
navigateUrl reg scope proxy url = navigateUrlWith reg scope proxy url ["maxChars" .= zhihuMaxChars, "maxElements" .= (40 :: Int)]

navigateUrlWith :: BrowserRegistry -> BrowserScope -> Maybe Text -> Text -> [(Key, Value)] -> IO (Either Text Value)
navigateUrlWith reg scope proxy url fields =
  withBrowserSession reg scope $
    getCamoSession reg scope >>= \case
      Nothing -> freshNavigate
      Just sid ->
        callBrowserTool reg scope "browse_session_navigate" (navArgs sid) >>= \case
          Left err -> case browserErrorKind err of
            BrowserSessionBlocked -> dropSession reg scope sid True >> freshNavigate
            BrowserSessionGone -> dropSession reg scope sid False >> freshNavigate
            BrowserTransportLost -> pure (Left (renderBrowserError err))
            BrowserCallFailed -> pure (Left (renderBrowserError err))
          Right value -> pure (Right value)
  where
    freshNavigate =
      startSession reg scope proxy
        >>= either
          (pure . Left)
          (\sid -> first renderBrowserError <$> callBrowserTool reg scope "browse_session_navigate" (navArgs sid))
    navArgs sid = withSid sid (("url" .= url) : fields)

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
                pure (Left "不是知乎链接；其他网页用 browser action=open 打开")
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
            | otherwise -> pure (Right (browserView (BrowserBudget zhihuMaxChars 40) "read" v))
          Nothing -> pure (Right (browserView (BrowserBudget zhihuMaxChars 40) "read" v))

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
