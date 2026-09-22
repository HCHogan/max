-- | Dispatch cancellation encloses both normal work and failure handling.
-- Cancellation during publication bookkeeping reaches the same owner as
-- cancellation during model or tool execution.
module Max.Turn.Failure (handleTurnFailures) where

import Control.Exception (SomeException)
import Data.Text (Text)
import Effectful
import Effectful.Exception (catch)
import Max.ReplySend (ReplyPublicationException (..))
import Max.Tasks (TaskCancelled (..))
import Max.Util (catchSync)

handleTurnFailures :: (SomeException -> Eff es a) -> (Text -> Eff es a) -> Eff es a -> Eff es a -> Eff es a
handleTurnFailures crashed publication cancelled action =
  publishing `catch` \TaskCancelled -> cancelled
  where
    publishing = (action `catchSync` crashed) `catch` \(ReplyPublicationException detail) -> publication detail
