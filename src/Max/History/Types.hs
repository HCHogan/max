-- | Canonical conversation read models and row codecs, without storage IO.
module Max.History.Types (MessageCursor (..), HistoryItem (..), LedgerItem (..), HistoryPage (..), bestName) where

import Control.Applicative ((<|>))
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Max.IR (nonBlank)

-- | A database-owned total order over message ingestion.  Unlike platform
-- message ids or timestamps, this is unique and monotonic.
newtype MessageCursor = MessageCursor {ingestSeq :: Int64}
  deriving stock (Show, Eq, Ord)

-- | The fields needed to render a message as a line of prompt context.
--
-- Every identifier here is the canonical one (ADR 004): 'canonicalId' is
-- what the model reads as @#\<id\>@ and passes back to every tool, and
-- 'authorPrincipalId' is what it reads as @[\@#\<id\>]@.  The
-- compatibility bigints are not projected at all — they exist for the
-- session/command/admin plumbing, and nothing that renders to a model or a
-- human needs them.
data HistoryItem = HistoryItem
  { canonicalId :: !Int64,
    authorPrincipalId :: !Int64,
    -- | Did the bot say this?  Decided in SQL by comparing two
    -- compatibility columns of the /same row/ — @self_id@ is the bot's id
    -- on the endpoint that carried this message, so the comparison is
    -- within one id space by construction and stays correct for the
    -- pre-ADR-003 rows that predate 'message_origin'.
    fromBot :: !Bool,
    senderNickname :: !(Maybe Text),
    -- | 群名片 — the sender's per-group display name.  This is what
    -- other members actually see and call them by, so rendering
    -- prefers it over the (global) nickname.
    senderCard :: !(Maybe Text),
    renderedText :: !Text,
    receivedAt :: !UTCTime,
    -- | The message this one quotes (@reply_to_canonical_message_id@), if
    -- any.  Rendered as a @[↩#\<id\>]@ handle so the model can walk the
    -- quote chain via @get_message_by_id@; 'Nothing' for non-replies.
    replyTo :: !(Maybe Int64)
  }
  deriving stock (Show)

instance FromRow HistoryItem where
  fromRow =
    HistoryItem
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

-- | One raw-ledger row together with whether the old memory extractor should
-- render it into its transcript.  Pagination includes every row before this
-- policy flag is considered, so filtered commands/synthetic/forward children
-- cannot create cursor holes.
data LedgerItem = LedgerItem
  { cursor :: !MessageCursor,
    history :: !HistoryItem,
    transcriptEligible :: !Bool
  }
  deriving stock (Show)

instance FromRow LedgerItem where
  fromRow =
    LedgerItem . MessageCursor
      <$> field
      <*> fromRow
      <*> field

data HistoryPage = HistoryPage
  { items :: ![LedgerItem],
    hasMore :: !Bool
  }
  deriving stock (Show)

-- | How a speaker is named in every transcript: what the other members see —
-- 群名片 first, then nickname, then the bare principal id when the platform
-- gave us neither (QQ sends @\"\"@ for an unset card, so blanks count as
-- absent).
--
-- Deliberately no platform label.  Which transport carried a message is
-- routing metadata: the delivery layer needs it to pick capabilities and to
-- attribute a mirrored copy, the model does not.  Naming it here did two
-- things wrong — it made the unlabelled platform the transcript's implicit
-- home, and it split one principal into "QQ · 张三" and "Matrix · 张三",
-- which is precisely what principal identities exist to prevent.
bestName :: HistoryItem -> Text
bestName h =
  fromMaybe (T.pack (show h.authorPrincipalId)) (blankless h.senderCard <|> blankless h.senderNickname)
  where
    blankless = (>>= nonBlank)
