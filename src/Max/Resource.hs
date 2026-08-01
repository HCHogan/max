-- |
-- Small ownership transitions for resources whose physical lifetime lives
-- outside this process (containers today).  The registry is the source of
-- truth for cleanup, so acquisition commits the registry entry while async
-- exceptions are masked, and release removes it only after physical cleanup
-- has completed.
module Max.Resource
  ( acquireRegistered,
    releaseRegistered,
  )
where

import Control.Exception (mask, onException)

-- | Acquire an external resource and atomically transfer its ownership to a
-- registry.  @rollback@ must be idempotent: it also runs when acquisition
-- reports 'Left', because an external command may have created part of the
-- resource before reporting failure.
--
-- The potentially blocking acquisition runs at the caller's masking state.
-- Once it returns successfully, registration is the masked commit point.  If
-- cancellation or a synchronous exception lands before that point, rollback
-- owns the external resource instead.
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
