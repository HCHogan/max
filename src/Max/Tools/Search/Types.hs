-- | Configuration data for the search tool, kept independent of the effectful
-- tool implementation so runtime configuration generations do not form a
-- module cycle through @Effects.Tools -> Effects.LLM@.
module Max.Tools.Search.Types
  ( SearchConfig (..),
  )
where

import Data.Text (Text)

data SearchConfig = SearchConfig
  { scTavilyApiKey :: !Text,
    scDefaultMaxResults :: !Int,
    scTimeoutSeconds :: !Int
  }
  deriving stock (Show, Eq)
