-- | One action-based browser tool and the dedicated Zhihu reader. Session IDs
-- and launch options are host-owned; uncertain operations are never replayed.
module Max.Tools.Browser
  ( browserToolsAt,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Browser.View
import Max.Effects.Browser
  ( Browser,
    SessionMethod (SessionAction, SessionInspect, SessionSnapshot),
    navigateUrlWith,
    readZhihu,
    sessionRequest,
  )
import Max.Effects.ToolOutput
  ( InlineMedia (..),
    ToolOutput,
    canQueueInlineMediaOnce,
    queueInlineMediaOnce,
  )
import Max.Effects.Tools (Tool (..), ToolFault (..), ToolOutcome (..), ToolRetryClass (..), ToolRunner (..))
import Max.Tools.Schema
  ( boundedIntegerParam,
    enumParam,
    numberParam,
    stringParam,
    toolObject,
  )

browserToolsAt :: (Browser :> es, ToolOutput :> es) => Bool -> [Tool es]
browserToolsAt canEvaluate =
  [browserTool canEvaluate, viewZhihuTool]

--------------------------------------------------------------------------------
-- Session plumbing.

-- | Forget the turn's session; when it is wedged-but-alive, also
-- close it server-side to free the slot (best-effort).
-- Argument helpers (model args arrive as a JSON object).
argText :: Value -> Key -> Maybe Text
argText v k = parseMaybe (withObject "args" (.: k)) v

-- | Copy the given keys from the model's args into MCP argument
-- fields, skipping absent ones.
passThrough :: Value -> [Key] -> [(Key, Value)]
passThrough (Object o) keys = [(k, x) | k <- keys, Just x <- [KM.lookup k o]]
passThrough _ _ = []

-- | Some models fill every schema field with a placeholder. Empty strings and
-- lists mean "not supplied" (fill keeps an empty text: it clears the field),
-- and a scroll of 0,0 means the default scroll.
dropPlaceholders :: Value -> Value
dropPlaceholders (Object o) = Object (stillScrolls (KM.filterWithKey supplied o))
  where
    supplied key = \case
      String text -> not (T.null (T.strip text)) || (key == "text" && KM.lookup "action" o == Just "fill")
      Array items -> not (null items)
      Null -> False
      _ -> True
    stillScrolls fields
      | all (\key -> maybe True (== Number 0) (KM.lookup key fields)) ["deltaX", "deltaY"] = KM.delete "deltaX" (KM.delete "deltaY" fields)
      | otherwise = fields
dropPlaceholders other = other

-- | Actions that only observe the page. When they fail nothing external has
-- happened, so they can be retried; other failures stay outcome-unknown.
observingActions :: [Text]
observingActions = ["snapshot", "read", "find", "links", "forms", "screenshot", "dialog", "collect", "wait_for"]

--------------------------------------------------------------------------------
-- Tools.

browserTool :: (Browser :> es, ToolOutput :> es) => Bool -> Tool es
browserTool canEvaluate =
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
            ("offset", boundedIntegerParam 0 1000000 0),
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
      toolRunner = OutcomeRunner $ \raw -> do
        canAttach <- canQueueInlineMediaOnce "browser.screenshot"
        let args = dropPlaceholders raw
            action = fromMaybe "" (argText args "action")
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
            request = case action of
              "open" -> Right (navigateUrlWith (fromMaybe "" (argText args "url")) (limits <> passThrough args ["timeout", "selector"]))
              "snapshot" -> Right (sessionRequest SessionSnapshot (limits <> passThrough args ["selector", "frame"]))
              "screenshot"
                | not canAttach ->
                    Right (fmap (setScreenshotNote "screenshot not attached: this turn's screenshot or attachment quota is exhausted") <$> sessionRequest SessionSnapshot limits)
              _
                | action `elem` ["read", "find", "links", "forms", "screenshot", "dialog", "collect"] ->
                    Right (sessionRequest SessionInspect (("action" .= action) : limits <> passThrough args ["selector", "frame", "mode", "offset", "query", "response", "promptText", "maxScrolls", "waitMs", "timeout"]))
              "evaluate" | not canEvaluate -> Left "evaluate requires a browser task; use task_start profile=browser"
              "wait_for" | null (passThrough args ["selector", "loadState"]) -> Left "wait_for requires selector or loadState"
              _
                | action `elem` ["click", "fill", "type", "press", "hover", "select", "scroll", "wait_for", "evaluate"] ->
                    let actionType = if action == "wait_for" then "waitFor" else action
                        fields =
                          ["type" .= actionType]
                            <> passThrough args ["selector", "frame", "key", "delay", "deltaY", "deltaX", "state", "loadState", "timeout", "expression"]
                            <> (if action == "fill" then ["value" .= argText args "text"] else passThrough args ["text", "value"])
                            <> ["maxChars" .= budget.maxChars | action == "evaluate"]
                     in Right (sessionRequest SessionAction (("action" .= object fields) : limits))
              _ -> Left "unknown browser action"
            rejected message = pure (ToolRejected (ToolFault "invalid_arguments" message RetrySafe))
        case request of
          _ | not (null missing) -> rejected ("missing required arguments for browser action: " <> T.intercalate ", " (map Key.toText missing))
          Left message -> rejected message
          Right send -> do
            result <- send
            withImage <- case result of
              Left err -> pure (Left err)
              Right value -> Right <$> attachBrowserScreenshot budget action canAttach value
            pure $ case withImage of
              Right value -> ToolCommitted (browserView budget action value)
              Left err
                | action `elem` observingActions -> ToolFailedBeforeEffect (ToolFault "tool_error" (browserFailureView budget action err) RetrySafe)
                | otherwise -> ToolOutcomeUnknown (ToolFault "tool_error" (browserFailureView budget action err) RetryUnsafe)
    }

-- The media queue is scoped to the actual Agent turn, so task generations and
-- rebuilt adapters cannot reset the one-screenshot budget.
attachBrowserScreenshot :: (Browser :> es, ToolOutput :> es) => BrowserBudget -> Text -> Bool -> Value -> Eff es Value
attachBrowserScreenshot budget action available value
  | not (browserNeedsScreenshot action value) = pure value
  | not available = pure (setScreenshotNote "screenshot not attached: this turn's screenshot or attachment quota is exhausted" value)
  | otherwise = do
      captured <-
        if action == "screenshot"
          then pure (Right value)
          else sessionRequest SessionInspect ["action" .= ("screenshot" :: Text), "maxChars" .= budget.maxChars, "maxElements" .= budget.maxElements]
      case captured of
        Left err -> pure (setScreenshotNote ("screenshot unavailable: " <> T.take 200 err) value)
        Right imageResult -> case imageOf imageResult of
          Nothing -> pure (setScreenshotNote "screenshot unavailable: no image returned" value)
          Just dataUrl -> do
            queued <- queueInlineMediaOnce "browser.screenshot" (InlineMedia "browser viewport screenshot" dataUrl Nothing)
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
viewZhihuTool :: (Browser :> es) => Tool es
viewZhihuTool =
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
      toolRunner = LegacyRunner $ \args -> do
        case argText args "url" of
          Nothing -> pure (Left "missing required argument: url")
          Just url
            | not ("zhihu.com" `T.isInfixOf` url) ->
                pure (Left "不是知乎链接；其他网页用 browser action=open 打开")
            | otherwise -> readZhihu url
    }
