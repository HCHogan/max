-- | The embedding worker and explicit reindex share one process-local lock.
module Max.Embedding.Maintenance (EmbeddingLock, newEmbeddingLock, tryWithEmbeddingLock) where

import Control.Concurrent.MVar (MVar, newMVar, putMVar, tryTakeMVar)
import Data.Foldable (traverse_)
import Effectful
import Effectful.Exception (bracket)

newtype EmbeddingLock = EmbeddingLock (MVar ())

newEmbeddingLock :: IO EmbeddingLock
newEmbeddingLock = EmbeddingLock <$> newMVar ()

tryWithEmbeddingLock :: (IOE :> es) => EmbeddingLock -> Eff es a -> Eff es (Maybe a)
tryWithEmbeddingLock (EmbeddingLock lock) action =
  bracket
    (liftIO (tryTakeMVar lock))
    (traverse_ (liftIO . putMVar lock))
    (traverse (const action))
