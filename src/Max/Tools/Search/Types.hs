module Max.Tools.Search.Types
  ( SearchConfig (..),
  )
where

import Data.Text (Text)

data SearchConfig = SearchConfig
  { scExaApiKey :: !(Maybe Text),
    scDefaultMaxResults :: !Int,
    scTimeoutSeconds :: !Int
  }
  deriving stock (Show, Eq)
