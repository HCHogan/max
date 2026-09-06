-- | Episode handles and scoped expansion facts shared with read consumers.
module Max.Episode.Types (EpisodeHandle (..), episodeHandleText, parseEpisodeHandle, SourceRange (..), EpisodeExpansion (..)) where

import Data.Text (Text)
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
