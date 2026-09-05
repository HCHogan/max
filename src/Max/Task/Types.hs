module Max.Task.Types
  ( TaskProfile (..),
    profileName,
    parseProfile,
    taskGrants,
    taskHandle,
    parseTaskHandle,
  )
where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Text.Read (readMaybe)

data TaskProfile = Research | Browser | Sandbox
  deriving stock (Eq, Show)

profileName :: TaskProfile -> Text
profileName Research = "research"
profileName Browser = "browser"
profileName Sandbox = "sandbox"

parseProfile :: Text -> Maybe TaskProfile
parseProfile "research" = Just Research
parseProfile "browser" = Just Browser
parseProfile "sandbox" = Just Sandbox
parseProfile _ = Nothing

taskGrants :: TaskProfile -> Map Text Text -> Map Text Text
taskGrants profile = Map.filterWithKey (\name _ -> name `elem` allowed)
  where
    allowed =
      [ "web_search",
        "maxops_operations",
        "maxops_query",
        "get_message_by_id",
        "context_search",
        "context_expand",
        "view_forward",
        "memory_list",
        "view_image",
        "view_video",
        "view_avatar",
        "view_bilibili",
        "use_skill",
        "task_start",
        "task_status",
        "task_list",
        "task_steer"
      ]
        <> case profile of
          Research -> []
          Browser ->
            [ "browser_navigate",
              "browser_snapshot",
              "browser_click",
              "browser_type",
              "browser_scroll",
              "browser_press_key",
              "browser_screenshot",
              "browser_back",
              "browser_wait_for",
              "view_zhihu"
            ]
          Sandbox ->
            [ "sandbox_list",
              "sandbox_create",
              "sandbox_destroy",
              "sandbox_exec",
              "sandbox_read_file",
              "sandbox_write_file",
              "import_file_to_sandbox",
              "nix_search"
            ]

taskHandle :: Int64 -> Text
taskHandle identifier = "task#" <> T.pack (show identifier)

parseTaskHandle :: Text -> Maybe Int64
parseTaskHandle raw = do
  digits <- T.stripPrefix "task#" (T.strip raw)
  if T.null digits || T.any (\character -> character < '0' || character > '9') digits
    then Nothing
    else do
      identifier <- readMaybe (T.unpack digits)
      if identifier > 0 then Just identifier else Nothing
