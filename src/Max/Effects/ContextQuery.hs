{-# LANGUAGE TypeFamilies #-}

-- | Preview consumers can collect a snapshot, without publishing or arbitrary IO.
module Max.Effects.ContextQuery (ContextQuery, collectContextPreview, runContextQuery) where

import Effectful
  ( Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    type (:>),
  )
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Context.Types (ContextSnapshot)
import Max.Prompt.Request (PromptRequest)

data ContextQuery :: Effect where
  PreviewContext :: PromptRequest -> ContextQuery m ContextSnapshot

type instance DispatchOf ContextQuery = Dynamic

collectContextPreview :: (ContextQuery :> es) => PromptRequest -> Eff es ContextSnapshot
collectContextPreview = send . PreviewContext

runContextQuery :: (PromptRequest -> Eff es ContextSnapshot) -> Eff (ContextQuery : es) a -> Eff es a
runContextQuery collect = interpret $ \_ -> \case
  PreviewContext request -> collect request
