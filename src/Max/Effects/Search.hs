{-# LANGUAGE TypeFamilies #-}

-- | Search requests carry no credentials, URLs, managers or host IO actions.
module Max.Effects.Search (Search, searchWeb, runSearch) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful
  ( Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    type (:>),
  )
import Effectful.Dispatch.Dynamic (interpret, send)

data Search :: Effect where
  SearchWeb :: Text -> Int -> Search m (Either Text Value)

type instance DispatchOf Search = Dynamic

searchWeb :: (Search :> es) => Text -> Int -> Eff es (Either Text Value)
searchWeb query limit = send (SearchWeb query limit)

runSearch :: (Text -> Int -> Eff es (Either Text Value)) -> Eff (Search : es) a -> Eff es a
runSearch search = interpret $ \_ -> \case
  SearchWeb query limit -> search query limit
