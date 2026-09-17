-- | Episode handles and scoped expansion facts shared with read consumers.
module Max.Episode.Types (CompartmentId (..), ActiveCompartment (..), EpisodeHandle (..), episodeHandleText, parseEpisodeHandle, SourceRange (..), EpisodeExpansion (..)) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Database.PostgreSQL.Simple.FromField (FromField)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.ToField (ToField)
import Max.History.Types (LedgerItem, MessageCursor (..))

-- | An unguessable model-facing reference to one immutable compartment.
-- Internal sequence ids never cross the prompt/tool boundary, and possession
-- of a handle is not authority: the scoped episode reader always applies the current
-- recall policy again.
newtype EpisodeHandle = EpisodeHandle {unEpisodeHandle :: UUID}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField)

episodeHandleText :: EpisodeHandle -> Text
episodeHandleText = UUID.toText . (.unEpisodeHandle)

parseEpisodeHandle :: Text -> Maybe EpisodeHandle
parseEpisodeHandle = fmap EpisodeHandle . UUID.fromText

data SourceRange = SourceRange
  { srStart :: !MessageCursor,
    srEnd :: !MessageCursor,
    srHash :: !Text,
    srMessageCount :: !Int
  }
  deriving stock (Show, Eq)

instance FromRow SourceRange where
  fromRow =
    SourceRange . MessageCursor
      <$> field
      <*> (MessageCursor <$> field)
      <*> field
      <*> field

data EpisodeExpansion = EpisodeExpansion
  { expansionHandle :: !EpisodeHandle,
    expansionRange :: !SourceRange,
    expansionState :: !Text,
    expansionSourceHashMatches :: !Bool,
    expansionMessages :: ![LedgerItem],
    expansionHasMore :: !Bool,
    expansionNextCursor :: !(Maybe MessageCursor)
  }
  deriving stock (Show)

newtype CompartmentId = CompartmentId {unCompartmentId :: Int64}
  deriving stock (Show, Eq, Ord)
  deriving newtype (FromField, ToField, FromJSON, ToJSON)

data ActiveCompartment = ActiveCompartment
  { activeCompartmentId :: !CompartmentId,
    activeExpandHandle :: !EpisodeHandle,
    activeRange :: !SourceRange,
    activeStartedAt :: !UTCTime,
    activeEndedAt :: !UTCTime,
    -- | True when raw rows for this conversation exist between the previous
    -- active compartment and this one.  The prompt collector uses the newest
    -- gap-free suffix, so a partial historical backfill can never masquerade
    -- as complete chronological coverage.
    activeGapBefore :: !Bool,
    activeSummaryP1 :: !Text,
    activeSummaryP2 :: !Text,
    activeSummaryP3 :: !Text,
    activeKind :: !Text,
    activeImportance :: !Double,
    activeConfidence :: !Double,
    activeMaterializationVersion :: !Int64
  }
  deriving stock (Show, Eq)

-- | One policy-checked page of the immutable source range behind a summary.
-- Pages contain ledger rows, not re-summarized text, including rows that were
-- deliberately excluded from the normal prompt transcript.
instance FromRow ActiveCompartment where
  fromRow =
    ActiveCompartment
      <$> field
      <*> field
      <*> (SourceRange . MessageCursor <$> field <*> (MessageCursor <$> field) <*> field <*> field)
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
