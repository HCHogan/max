-- | Fallible checks which must finish before a reload reaches its atomic
-- publication point.
module Max.Reload.Prepare
  ( ListenerEndpoint,
    preflightChangedListener,
  )
where

import Control.Exception (IOException, bracket, throwIO, try)
import Data.Text (Text)
import Data.Text qualified as T
import Network.Socket qualified as Socket

type ListenerEndpoint = (Text, Int)

-- | Prove that a newly introduced listener address is currently bindable.
-- An unchanged address is deliberately skipped: the active generation is
-- already listening on it and therefore supplies the stronger proof.  Its
-- replacement binds after the old generation begins retirement.
preflightChangedListener :: Maybe ListenerEndpoint -> Maybe ListenerEndpoint -> IO ()
preflightChangedListener oldEndpoint newEndpoint
  | oldEndpoint == newEndpoint = pure ()
  | otherwise = maybe (pure ()) (uncurry preflightListener) newEndpoint

preflightListener :: Text -> Int -> IO ()
preflightListener host port = Socket.withSocketsDo $ do
  addresses <-
    Socket.getAddrInfo
      (Just Socket.defaultHints {Socket.addrSocketType = Socket.Stream})
      (Just (T.unpack host))
      (Just (show port))
  tryAddresses Nothing addresses
  where
    tryAddresses Nothing [] = ioError (userError "listener address did not resolve")
    tryAddresses (Just err) [] = throwIO err
    tryAddresses _previous (address : rest) = do
      result <-
        try @IOException
          . bracket
            (Socket.openSocket address)
            Socket.close
          $ \socket -> do
            Socket.setSocketOption socket Socket.ReuseAddr 1
            Socket.bind socket address.addrAddress
      case result of
        Right () -> pure ()
        Left err -> tryAddresses (Just err) rest
