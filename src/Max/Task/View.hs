-- | Bounded, host-rendered task context. Queries return facts rather than
-- constructing model instructions or public handles inside PostgreSQL.
module Max.Task.View
  ( TaskEventView (..),
    AttemptHistory (..),
    JournalHistory (..),
    TaskHistory (..),
    renderTaskInbox,
    renderTaskHistory,
    renderTaskNotification,
  )
where

import Data.Aeson (Value, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Task.Types (taskHandle)

data TaskEventView = TaskEventView
  { eventId :: !Int64,
    kind :: !Text,
    principal :: !(Maybe Int64),
    body :: !Text
  }
  deriving stock (Eq, Show)

data JournalHistory = JournalHistory
  { tool :: !Text,
    state :: !Text,
    preview :: !Text
  }
  deriving stock (Eq, Show)

data AttemptHistory = AttemptHistory
  { attempt :: !Int,
    revision :: !Int,
    report :: !(Maybe Value),
    journal :: ![JournalHistory]
  }
  deriving stock (Eq, Show)

data TaskHistory = TaskHistory
  { progress :: !(Maybe Value),
    attempts :: ![AttemptHistory]
  }
  deriving stock (Eq, Show)

renderTaskInbox :: [TaskEventView] -> Text
renderTaskInbox = T.intercalate "\n" . map render
  where
    render event =
      "event#"
        <> tshow event.eventId
        <> " ["
        <> event.kind
        <> "] principal#"
        <> maybe "host" tshow event.principal
        <> ": "
        <> event.body

renderTaskHistory :: TaskHistory -> Text
renderTaskHistory history =
  maybe "" (\value -> "latest progress: " <> jsonText value <> "\n") history.progress
    <> T.intercalate "\n" (map renderAttempt history.attempts)
  where
    renderAttempt entry =
      "attempt "
        <> tshow entry.attempt
        <> " revision "
        <> tshow entry.revision
        <> ": "
        <> maybe "no committed report; inspect journal before repeating effects" jsonText entry.report
        <> "\n"
        <> T.intercalate "\n" (map renderJournal entry.journal)
    renderJournal entry = entry.tool <> " [" <> entry.state <> "] " <> entry.preview

renderTaskNotification :: Int64 -> Int -> Value -> Text
renderTaskNotification task revision body = taskHandle task <> " revision " <> tshow revision <> "\n" <> T.take 80000 (jsonText body)

jsonText :: Value -> Text
jsonText = TE.decodeUtf8 . LBS.toStrict . encode

tshow :: (Show a) => a -> Text
tshow = T.pack . show
