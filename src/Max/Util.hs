module Max.Util
  ( catchSync,
    trySync,
    trySyncIO,
  )
where

import Control.Exception qualified as CE
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

-- | 'try'-shaped 'catchSync': synchronous exceptions come back as
-- 'Left', async-tagged ones (cancellation, shutdown) keep flying.
trySync :: Eff es a -> Eff es (Either SomeException a)
trySync act = (Right <$> act) `catchSync` (pure . Left)

-- | IO-level sibling of 'catchSync' for the error-to-'Left' pattern:
-- like @try \@SomeException@, but anything tagged 'SomeAsyncException'
-- (timeouts, 'Max.Tasks.TaskCancelled', shutdown) is re-raised instead
-- of being surfaced as a 'Left'.  Use this instead of a bare @try@
-- around blocking calls (HTTP etc.), otherwise cancellation delivered
-- mid-call gets swallowed into an error value.
trySyncIO :: IO a -> IO (Either SomeException a)
trySyncIO act =
  (Right <$> act) `CE.catch` \e ->
    case fromException e :: Maybe SomeAsyncException of
      Just _ -> CE.throwIO e
      Nothing -> pure (Left e)
