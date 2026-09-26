{-# LANGUAGE ForeignFunctionInterface #-}

-- | Poll-driven Wasmtime stores. No guest callback enters Haskell; a store
-- retains only data between steps. The owner serializes all resume operations.
module Max.CodeMode.Wasm
  ( WasmLimits (..),
    WasmExit (..),
    Guest,
    GuestCall (..),
    GuestStep (..),
    defaultWasmLimits,
    withGuest,
    resumeGuest,
    watToWasm,
  )
where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, swapMVar)
import Control.Exception qualified as Exception
import Control.Monad (unless, void, when)
import Data.Aeson (Value, eitherDecodeStrict', encode, withObject, (.!=), (.:), (.:?))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word64, Word8)
import Effectful
import Effectful.Exception (bracket)
import Foreign.C (CInt (..), CSize (..), CString)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr)
import Foreign.Storable (peek)
import System.Timeout (timeout)

data WasmLimits = WasmLimits
  { wlFuel :: !Word64,
    wlMemoryBytes :: !Int64,
    wlTimeoutMicros :: !Int,
    wlModuleBytes :: !Int,
    wlHostCalls :: !Int
  }
  deriving stock (Show, Eq)

defaultWasmLimits :: WasmLimits
defaultWasmLimits = WasmLimits 10000000 (64 * 1024 * 1024) (30 * 1000000) (1024 * 1024) 128

data WasmExit = WasmCompleted | WasmHostStopped | WasmRejected !Text | WasmTrapped !Text | WasmTimedOut
  deriving stock (Show, Eq)

data GuestCall = GuestCall {gcId :: !Int, gcTool :: !Text, gcArgs :: !Value}
  deriving stock (Show, Eq)

data GuestStep = GuestCalls ![GuestCall] ![Int] !Int | GuestDone !Value | GuestTrap !WasmExit
  deriving stock (Show, Eq)

data WasmHandle

data Guest = Guest !(Ptr WasmHandle) !WasmLimits !(MVar Bool)

foreign import ccall unsafe "max_wasm_new" wasmNew :: IO (Ptr WasmHandle)

foreign import ccall unsafe "max_wasm_delete" wasmDelete :: Ptr WasmHandle -> IO ()

foreign import ccall unsafe "max_wasm_interrupt" wasmInterrupt :: Ptr WasmHandle -> IO ()

foreign import ccall safe "max_wasm_open" wasmOpen :: Ptr WasmHandle -> Ptr Word8 -> CSize -> Word64 -> Int64 -> CString -> CSize -> IO CInt

foreign import ccall safe "max_wasm_step" wasmStep :: Ptr WasmHandle -> Ptr Word8 -> CSize -> Ptr (Ptr Word8) -> Ptr CSize -> CString -> CSize -> IO CInt

foreign import ccall safe "max_wasm_wat" wasmWat :: Ptr Word8 -> CSize -> Ptr (Ptr Word8) -> Ptr CSize -> CString -> CSize -> IO CInt

foreign import ccall unsafe "max_wasm_free" wasmFree :: Ptr Word8 -> IO ()

-- | Resources outlive individual steps but not their owner. Cancellation joins
-- the safe FFI worker before releasing the store. A timeout covers CPU steps,
-- not host futures, and fuel is set exactly once for the whole program.
withGuest :: (IOE :> es) => WasmLimits -> ByteString -> ByteString -> (Guest -> GuestStep -> Eff es a) -> Eff es a
withGuest limits binary input use = bracket (liftIO acquire) (liftIO . release) $ \guest@(Guest handle _ suspended) -> do
  initial <-
    liftIO $
      if invalid
        then pure (GuestTrap (WasmTrapped "invalid guest resources or module size"))
        else do
          opened <- timed guest $ BS.useAsCStringLen binary $ \(bytes, size) -> allocaBytes 4096 $ \message -> do
            code <- wasmOpen handle (castPtr bytes) (fromIntegral size) limits.wlFuel limits.wlMemoryBytes message 4096
            if code == 0 then pure Nothing else Just . WasmTrapped <$> readDiagnostic message
          case opened of
            Nothing -> pure (GuestTrap WasmTimedOut)
            Just (Just err) -> pure (GuestTrap err)
            Just Nothing -> runGuestStep guest input
  liftIO (void (swapMVar suspended (isSuspended initial)))
  use guest initial
  where
    invalid = limits.wlFuel == 0 || limits.wlMemoryBytes <= 0 || limits.wlTimeoutMicros <= 0 || limits.wlModuleBytes <= 0 || limits.wlHostCalls <= 0 || BS.length binary > limits.wlModuleBytes || BS.length input > 1024 * 1024
    acquire = do
      handle <- wasmNew
      when (handle == nullPtr) $ Exception.throwIO (userError "could not allocate Wasmtime engine")
      Guest handle limits <$> newMVar False
    release (Guest handle _ suspended) = modifyMVar_ suspended (\_ -> wasmDelete handle >> pure False)

-- | At most 16 MiB of outcomes per step; the caller retains excess completions.
resumeGuest :: Guest -> [(Int, Value)] -> IO GuestStep
resumeGuest guest@(Guest _ _ suspended) outcomes = modifyMVar suspended $ \waiting ->
  if not waiting
    then pure (False, GuestTrap (WasmTrapped "guest is not suspended"))
    else do
      step <- runGuestStep guest (LBS.toStrict (encode outcomes))
      pure (isSuspended step, step)

isSuspended :: GuestStep -> Bool
isSuspended GuestCalls {} = True
isSuspended _ = False

runGuestStep :: Guest -> ByteString -> IO GuestStep
runGuestStep guest@(Guest handle _ _) input
  | BS.length input > 16 * 1024 * 1024 = pure (GuestTrap (WasmTrapped "resume exceeds 16 MiB"))
  | otherwise = do
      result <- timed guest $ BS.useAsCStringLen input $ \(bytes, size) ->
        allocaBytes 4096 $ \message -> alloca $ \outputPtr -> alloca $ \outputSize -> do
          code <- wasmStep handle (castPtr bytes) (fromIntegral size) outputPtr outputSize message 4096
          buffer <- peek outputPtr
          output <-
            if buffer == nullPtr
              then pure Nothing
              else do
                len <- peek outputSize
                Just <$> (BS.packCStringLen (castPtr buffer, fromIntegral len) `Exception.finally` wasmFree buffer)
          if code /= 0
            then case fmap decodeStep output of
              Just trapped@(GuestTrap _) -> pure trapped
              _ -> GuestTrap . WasmTrapped <$> readDiagnostic message
            else pure $ maybe (GuestTrap (WasmTrapped "guest step did not write output")) decodeStep output
      pure (maybe (GuestTrap WasmTimedOut) id result)

timed :: Guest -> IO a -> IO (Maybe a)
timed (Guest handle limits _) action = Exception.mask $ \restore -> do
  worker <- Async.async (restore action)
  let stop = Exception.uninterruptibleMask_ $ wasmInterrupt handle >> void (Async.waitCatch worker)
  result <- restore (timeout limits.wlTimeoutMicros (Async.wait worker)) `Exception.onException` stop
  case result of Nothing -> stop; Just _ -> pure ()
  pure result

decodeStep :: ByteString -> GuestStep
decodeStep bytes = either (GuestTrap . WasmTrapped . T.pack) id $ do
  value <- eitherDecodeStrict' bytes
  parseEither
    ( withObject "guest step" $ \o -> do
        let done = KeyMap.lookup "done" o
        err <- o .:? "error"
        case (done, err) of
          (Just result, _) -> pure (GuestDone result)
          (_, Just message) -> pure (GuestTrap (WasmTrapped message))
          _ ->
            GuestCalls
              <$> ( o .: "calls"
                      >>= traverse
                        ( withObject "guest call" $ \c -> do
                            unless (KeyMap.size c == 3) (fail "unexpected guest call fields")
                            GuestCall <$> c .: "id" <*> c .: "tool" <*> c .: "args"
                        )
                  )
              <*> (o .:? "cancel" .!= [])
              <*> o .: "waiting"
    )
    value

-- | Compile bounded host-authored WAT fixtures with the same pinned library.
watToWasm :: ByteString -> IO (Either Text ByteString)
watToWasm source
  | BS.length source > 1024 * 1024 = pure (Left "WAT exceeds fixture size limit")
  | otherwise = BS.useAsCStringLen source $ \(bytes, size) ->
      alloca $ \output -> alloca $ \lengthPtr -> allocaBytes 4096 $ \message -> do
        code <- wasmWat (castPtr bytes) (fromIntegral size) output lengthPtr message 4096
        if code /= 0
          then Left <$> readDiagnostic message
          else do
            buffer <- peek output
            len <- peek lengthPtr
            Right <$> (BS.packCStringLen (castPtr buffer, fromIntegral len) `Exception.finally` wasmFree buffer)

readDiagnostic :: CString -> IO Text
readDiagnostic pointer = TE.decodeUtf8With lenientDecode <$> BS.packCString pointer
