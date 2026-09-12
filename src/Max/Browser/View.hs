-- | One bounded model-facing view, independent of upstream payload sizes.
module Max.Browser.View (BrowserBudget (..), browserBudget, browserPayload, browserView, browserNeedsScreenshot, browserFailureView, boundedBrowserText) where

import Control.Applicative ((<|>))
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseMaybe)
import Data.ByteString.Lazy qualified as BL
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Max.MCP.Client (mcpTextContent)

data BrowserBudget = BrowserBudget {maxChars :: !Int, maxElements :: !Int}
  deriving stock (Show, Eq)

browserBudget :: Text -> Value -> BrowserBudget
browserBudget action args = BrowserBudget (limit "maxChars" 512 30000 chars) (limit "maxElements" 1 200 elements)
  where
    reading = action `elem` ["open", "snapshot", "read", "find", "links", "forms", "collect"]
    (chars, elements) = if reading then (6000, 40) else (1500, 20)
    limit key low high fallback = max low . min high . fromMaybe fallback $ parseMaybe (withObject "browser arguments" (.: key)) args

browserPayload :: Value -> Value
browserPayload value =
  fromMaybe (object ["text" .= mcpTextContent value]) $
    parseMaybe (withObject "MCP result" (.: "structuredContent")) value
      <|> decodeStrict (TE.encodeUtf8 (mcpTextContent value))

boundedBrowserText :: Int -> Text -> Text
boundedBrowserText budget value
  | T.length value <= budget = value
  | otherwise = T.take (max 0 (budget - T.length marker)) value <> T.take (max 0 budget) marker
  where
    marker = "\n[truncated]"

browserView :: BrowserBudget -> Text -> Value -> Value
browserView budget action raw =
  String . boundedBrowserText budget.maxChars $
    header <> notes <> "Content:\n" <> body
  where
    payload = browserPayload raw
    snapshot = fromMaybe payload (field "snapshot" payload)
    position = fromMaybe Null (field "position" payload)
    header =
      "Outcome: "
        <> action
        <> " ok"
        <> status
        <> "\n"
        <> "Page: "
        <> short (budget.maxChars `div` 10) (valueText (field "url" payload))
        <> " | "
        <> short (budget.maxChars `div` 20) (valueText (field "title" payload))
        <> "\n"
        <> "Position: "
        <> number "x"
        <> ","
        <> number "y"
        <> " viewport "
        <> number "width"
        <> "x"
        <> number "height"
        <> " pageHeight "
        <> number "pageHeight"
        <> "\n"
    status = maybe "" (\v -> " HTTP " <> short 12 (textOf v)) (field "status" snapshot)
    number key = short 10 (valueText (field key position))
    notes =
      boundedBrowserText (budget.maxChars `div` 3) . T.unlines $
        ["Note: navigation incomplete; inspect the content that arrived" | (field "navigation" payload >>= field "complete") == Just (Bool False)]
          <> ["Note: page navigated from " <> short 140 (textOf before) <> " to " <> short 140 (valueText (field "url" payload)) <> "; selectors are stale" | Just before <- [field "previousUrl" payload]]
          <> ["Note: " <> short 200 (textOf note) | note <- array (field "notes" payload)]
          <> ["Note: " <> fromMaybe "screenshot available with action=screenshot" (textField "screenshotNote" payload)]
    elements =
      T.unlines
        [ short 500 (T.intercalate " | " [valueText (field key element) | key <- ["selector", "role", "name"]])
        | element <- take budget.maxElements (array (field "elements" snapshot))
        ]
    body =
      boundedBrowserText (budget.maxChars `div` 2) elements
        <> maybe "" (\v -> "Result: " <> textOf v <> "\n") (field "action" payload >>= field "result")
        <> fromMaybe "" (textField "text" snapshot <|> textField "text" payload)
    short n = T.replace "\n" " " . boundedBrowserText n

browserFailureView :: BrowserBudget -> Text -> Text -> Text
browserFailureView budget action detail =
  -- Reserve the kernel's uncertainty suffix and the protocol's error prefix.
  boundedBrowserText (budget.maxChars - 64) $
    "Outcome: " <> action <> " failed; see diagnostic\nPage: ? | ?\nPosition: ? viewport ? pageHeight ?\nContent:\n" <> detail

browserNeedsScreenshot :: Text -> Value -> Bool
browserNeedsScreenshot action raw = action == "screenshot" || isJust (field "previousUrl" payload) || T.length content < 120
  where
    payload = browserPayload raw
    snapshot = fromMaybe payload (field "snapshot" payload)
    content = fromMaybe "" (textField "text" snapshot)

field :: Key -> Value -> Maybe Value
field key (Object fields) = KM.lookup key fields
field _ _ = Nothing

textField :: Key -> Value -> Maybe Text
textField key value = field key value >>= \case String text -> Just text; _ -> Nothing

array :: Maybe Value -> [Value]
array (Just (Array items)) = V.toList items
array _ = []

valueText :: Maybe Value -> Text
valueText = maybe "?" textOf

textOf :: Value -> Text
textOf (String value) = value
textOf value = TE.decodeUtf8 (BL.toStrict (encode value))
