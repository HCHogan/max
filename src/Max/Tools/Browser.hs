-- |
-- Browser tools exposed to the agent, proxied to a per-group
-- Playwright-MCP server (see "Max.Browser.Registry").  The container
-- is started lazily on the first call and reused across dispatches.
--
-- == The snapshot → ref → act loop
--
-- Interaction is driven by @browser_snapshot@, which returns
-- Playwright's accessibility snapshot (@snapshotForAI@): a compact YAML
-- of roles/labels/states where every interactive element carries a
-- stable @ref@ (e.g. @ref=e5@).  The model reads the snapshot, then
-- targets elements by @ref@ in @browser_click@ / @browser_type@.  No
-- screenshots, no vision required — but the whole toolset is only
-- offered to multimodal-capable profiles (gated in @app/Main.hs@).
--
-- Tool names and argument shapes mirror Playwright MCP exactly, so the
-- model's arguments pass straight through as MCP tool arguments.
module Max.Tools.Browser
  ( browserToolsFor,
  )
where

import Data.Aeson
import Data.Text (Text)
import Effectful
import Max.Browser.Registry (BrowserRegistry, callBrowserTool)
import Max.Effects.Tools (Tool (..))
import Max.MCP.Client (mcpTextContent)
import OneBot.Types (GroupId)

browserToolsFor :: IOE :> es => GroupId -> BrowserRegistry -> [Tool es]
browserToolsFor gid reg =
  [ navigateTool gid reg,
    snapshotTool gid reg,
    clickTool gid reg,
    typeTool gid reg,
    pressKeyTool gid reg,
    waitForTool gid reg,
    navigateBackTool gid reg
  ]

-- | Build one proxied tool: the model's @args@ object is forwarded
-- verbatim as the MCP tool arguments; the MCP text content comes back
-- under @result@.
proxied :: IOE :> es => GroupId -> BrowserRegistry -> Text -> Text -> Value -> Tool es
proxied gid reg name desc schema =
  Tool
    { toolName = name,
      toolDescription = desc,
      toolSchema = schema,
      toolRun = \args -> do
        res <- liftIO (callBrowserTool reg gid name args)
        pure $ case res of
          Left err -> Left err
          Right result -> Right (object ["result" .= mcpTextContent result])
    }

--------------------------------------------------------------------------------
-- Schemas / tools.

obj :: [(Key, Value)] -> [Text] -> Value
obj props required =
  object
    [ "type" .= ("object" :: Text),
      "properties" .= object props,
      "required" .= required
    ]

str :: Text -> Value
str desc = object ["type" .= ("string" :: Text), "description" .= desc]

navigateTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
navigateTool gid reg =
  proxied
    gid
    reg
    "browser_navigate"
    "Open a URL in the group's browser. Starts the browser on first use. After navigating, call browser_snapshot to see the page."
    (obj [("url", str "Absolute URL to open, e.g. https://example.com")] ["url"])

snapshotTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
snapshotTool gid reg =
  proxied
    gid
    reg
    "browser_snapshot"
    "Capture the current page as an accessibility snapshot (YAML of roles/labels/states). Each interactive element has a stable 'ref' you pass to browser_click / browser_type. Call this after navigating or after any action that changes the page; refs from an old snapshot may be stale."
    (obj [] [])

clickTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
clickTool gid reg =
  proxied
    gid
    reg
    "browser_click"
    "Click an element identified by its 'ref' from the latest browser_snapshot."
    ( obj
        [ ("element", str "Human-readable description of the element (for logging/permission)."),
          ("ref", str "Exact element ref from the latest snapshot, e.g. e5.")
        ]
        ["element", "ref"]
    )

typeTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
typeTool gid reg =
  proxied
    gid
    reg
    "browser_type"
    "Type text into an editable element identified by 'ref' from the latest snapshot. Set submit=true to press Enter afterwards."
    ( obj
        [ ("element", str "Human-readable description of the field."),
          ("ref", str "Exact element ref from the latest snapshot."),
          ("text", str "Text to type."),
          ("submit", object ["type" .= ("boolean" :: Text), "description" .= ("Press Enter after typing (default false)." :: Text)])
        ]
        ["element", "ref", "text"]
    )

pressKeyTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
pressKeyTool gid reg =
  proxied
    gid
    reg
    "browser_press_key"
    "Press a single key on the page, e.g. Enter, ArrowDown, Escape."
    (obj [("key", str "Key name, e.g. Enter or ArrowDown.")] ["key"])

waitForTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
waitForTool gid reg =
  proxied
    gid
    reg
    "browser_wait_for"
    "Wait for text to appear or disappear, or for a fixed time. Useful after an action that triggers async loading."
    ( obj
        [ ("text", str "Wait until this text appears on the page."),
          ("textGone", str "Wait until this text disappears."),
          ("time", object ["type" .= ("number" :: Text), "description" .= ("Wait this many seconds." :: Text)])
        ]
        []
    )

navigateBackTool :: IOE :> es => GroupId -> BrowserRegistry -> Tool es
navigateBackTool gid reg =
  proxied
    gid
    reg
    "browser_navigate_back"
    "Go back to the previous page in history."
    (obj [] [])
