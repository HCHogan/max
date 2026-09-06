-- | Ranked, scoped recall output, independent of candidate-query execution.
module Max.Recall.Types (RecallHit (..)) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Max.Episode.Types (EpisodeHandle)
import Max.Memory.Types (MemoryId)

data RecallHit = RecallHit
  { rhSource :: !Text,
    rhDedupKey :: !Text,
    rhSnippet :: !Text,
    rhOccurredAt :: !UTCTime,
    rhPrincipalId :: !(Maybe Int64),
    rhMessageId :: !(Maybe Int64),
    rhEpisodeHandle :: !(Maybe EpisodeHandle),
    rhMemoryId :: !(Maybe MemoryId),
    rhScore :: !Double,
    rhLexicalScore :: !(Maybe Double),
    rhSemanticScore :: !(Maybe Double),
    rhPinned :: !Bool,
    rhPermanent :: !Bool
  }
  deriving stock (Show, Eq)
