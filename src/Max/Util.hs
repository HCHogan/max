module Max.Util
  ( catchSync,
  )
where

import Control.Exception
  ( SomeAsyncException,
    SomeException,
    catch,
    fromException,
    throwIO,
  )
import Effectful (Eff, IOE, (:>))
import Effectful (withRunInIO)

-- | Catch only synchronous exceptions; re-raise anything tagged
-- 'SomeAsyncException' so cancellation and signals propagate normally.
catchSync ::
  IOE :> es =>
  Eff es a ->
  (SomeException -> Eff es a) ->
  Eff es a
catchSync act h = withRunInIO $ \run ->
  run act `catch` \e ->
    case fromException e :: Maybe SomeAsyncException of
      Just _ -> throwIO e
      Nothing -> run (h e)
