-- | Cancellation-safe registration and cleanup of external resources.
module Max.Resource
  ( acquireRegistered,
    releaseRegistered,
  )
where

import Control.Exception (mask, onException)

-- | Acquire at the caller's masking state, then register with exceptions masked.
-- Idempotent rollback handles 'Left' and exceptions before registration completes:
-- even failed acquisition may have created part of the external resource.
acquireRegistered ::
  IO (Either e resource) ->
  IO () ->
  (resource -> IO ()) ->
  IO (Either e resource)
acquireRegistered acquire rollback register = mask $ \restore -> do
  acquired <- restore acquire `onException` rollback
  case acquired of
    Left err -> rollback >> pure (Left err)
    Right resource -> do
      register resource `onException` rollback
      pure (Right resource)

-- | Release an externally owned resource, then forget its registry entry.
-- Cancellation or cleanup failure leaves the entry registered, so a later
-- cleanup pass can retry it instead of turning a live resource into an
-- untracked orphan.
releaseRegistered :: IO () -> IO () -> IO ()
releaseRegistered cleanup unregister = mask $ \restore -> do
  restore cleanup
  unregister
