-- | Learned group lingo as the prompt sees it.  Plain values only: the learner
-- and store decode rows into these, and rendering never needs a query.
module Max.Lingo.Types
  ( LingoExpression (..),
    LingoJargon (..),
    LingoView (..),
    emptyLingoView,
    nullLingoView,
  )
where

import Data.Int (Int64)
import Data.Text (Text)

-- | \"When /situation/, members say /style/\" with one real line it came from.
data LingoExpression = LingoExpression
  { leId :: !Int64,
    leSituation :: !Text,
    leStyle :: !Text,
    leHits :: !Int,
    leExample :: !Text
  }
  deriving stock (Show, Eq)

-- | A term whose meaning in this group differs from its context-free reading.
data LingoJargon = LingoJargon
  { ljTerm :: !Text,
    ljMeaning :: !Text,
    ljHits :: !Int
  }
  deriving stock (Show, Eq)

-- | What one prompt carries: a sample of expressions, the jargon terms the
-- recent conversation actually used, and the learned wordings Max's own recent
-- lines already keep repeating.
data LingoView = LingoView
  { lvExpressions :: ![LingoExpression],
    lvJargon :: ![LingoJargon],
    lvOverused :: ![Text]
  }
  deriving stock (Show, Eq)

emptyLingoView :: LingoView
emptyLingoView = LingoView [] [] []

nullLingoView :: LingoView -> Bool
nullLingoView view = null view.lvExpressions && null view.lvJargon && null view.lvOverused
