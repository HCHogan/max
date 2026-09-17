-- | Read adapter for diagnostics. Publication is not installed by this handler.
module Max.Prompt.Runtime (runContextQueryWithDatabase) where

import Effectful (Eff, IOE, type (:>))
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob)
import Max.Effects.ContextQuery (ContextQuery, runContextQuery)
import Max.Prompt.Collect qualified as Collect
  ( collectContextPreview,
  )

runContextQueryWithDatabase :: (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) => Eff (ContextQuery : es) a -> Eff es a
runContextQueryWithDatabase = runContextQuery Collect.collectContextPreview
