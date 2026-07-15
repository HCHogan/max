module Max.Util
  ( catchSync,
  )
where

import Effectful (Eff)
import Effectful.Exception
  ( SomeAsyncException,
    SomeException,
    catch,
    fromException,
    throwIO,
  )

-- | Catch only synchronous exceptions; re-raise anything tagged
-- 'SomeAsyncException' so cancellation and signals propagate normally.
catchSync ::
  Eff es a ->
  (SomeException -> Eff es a) ->
  Eff es a
catchSync act h =
  act `catch` \e ->
    case fromException e :: Maybe SomeAsyncException of
      Just _ -> throwIO e
      Nothing -> h e
