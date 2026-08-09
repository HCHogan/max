-- | Stable identities for ADR 006 monitors.  Surrogate ids stay inside the
-- host; the model-visible namespace is the conversation-scoped @m#<n>@
-- ordinal and is resolved under a freshly minted ConversationScope.
module Max.Monitor.Types
  ( MonitorId (..),
    MonitorOrdinal (..),
    MonitorRef (..),
    MonitorFireId (..),
    monitorHandleText,
    parseMonitorHandle,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.ToField (ToField)
import Text.Read (readMaybe)

newtype MonitorId = MonitorId {unMonitorId :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

newtype MonitorOrdinal = MonitorOrdinal {unMonitorOrdinal :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

data MonitorRef = MonitorRef
  { mrMonitorId :: !MonitorId,
    mrMonitorOrdinal :: !MonitorOrdinal
  }
  deriving stock (Show, Eq, Ord)

newtype MonitorFireId = MonitorFireId {unMonitorFireId :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

monitorHandleText :: MonitorOrdinal -> Text
monitorHandleText ordinal = "m#" <> T.pack (show ordinal.unMonitorOrdinal)

-- | Exact handle grammar.  Bare surrogate ids are deliberately not aliases:
-- possession of syntax never substitutes for the conversation scope check.
parseMonitorHandle :: Text -> Maybe MonitorOrdinal
parseMonitorHandle raw = do
  digits <- T.stripPrefix "m#" (T.strip raw)
  value <- readMaybe (T.unpack digits)
  if value > 0 then Just (MonitorOrdinal value) else Nothing
