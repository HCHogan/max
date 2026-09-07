{-# LANGUAGE ForeignFunctionInterface #-}

-- | Embedded Wasmtime mechanics only: memory, resources and scoped callbacks.
-- Tool authority, journal and language SDKs do not belong to this module.
module Max.CodeMode.Wasm
  ( WasmLimits (..),
    WasmExit (..),
    defaultWasmLimits,
    runWasm,
    runWasmWithInput,
    watToWasm,
  )
where

import Control.Concurrent.Async qualified as Async
import Control.Concurrent.STM
import Control.Exception qualified as Exception
import Control.Monad (void, when)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Either (fromRight)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word64, Word8)
import Effectful
import Effectful.Concurrent (Concurrent, threadDelay)
import Effectful.Concurrent.Async (race)
import Effectful.Exception (bracket, throwIO)
import Foreign.C (CInt (..), CSize (..), CString)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (FunPtr, Ptr, castPtr, nullPtr)
import Foreign.StablePtr (StablePtr, deRefStablePtr, freeStablePtr, newStablePtr)
import Foreign.Storable (peek)

-- Limits are host configuration, never guest-provided authority.
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

data WasmExit = WasmCompleted | WasmHostStopped | WasmTrapped !Text | WasmTimedOut
  deriving stock (Show, Eq)

data WasmHandle

type ToolCallback = StablePtr Mailbox -> Ptr Word8 -> CSize -> Ptr Word8 -> CSize -> IO Int32

foreign import ccall unsafe "max_wasm_new" wasmNew :: IO (Ptr WasmHandle)

foreign import ccall unsafe "max_wasm_delete" wasmDelete :: Ptr WasmHandle -> IO ()

foreign import ccall unsafe "max_wasm_interrupt" wasmInterrupt :: Ptr WasmHandle -> IO ()

foreign import ccall safe "max_wasm_run" wasmRun :: Ptr WasmHandle -> Ptr Word8 -> CSize -> Word64 -> Int64 -> Ptr Word8 -> CSize -> Ptr (Ptr Word8) -> Ptr CSize -> FunPtr ToolCallback -> StablePtr Mailbox -> CString -> CSize -> IO CInt

foreign export ccall "max_haskell_wasm_dispatch" dispatchCallback :: ToolCallback

foreign import ccall "&max_haskell_wasm_dispatch" callbackPointer :: FunPtr ToolCallback

foreign import ccall safe "max_wasm_wat" wasmWat :: Ptr Word8 -> CSize -> Ptr (Ptr Word8) -> Ptr CSize -> CString -> CSize -> IO CInt

foreign import ccall unsafe "max_wasm_free" wasmFree :: Ptr Word8 -> IO ()

data Pending = Pending !ByteString !(TMVar (Maybe ByteString))

data Mailbox = Mailbox !(TQueue Pending) !(TVar Bool)

data RunningWasm = RunningWasm
  { rwHandle :: !(Ptr WasmHandle),
    rwCallback :: !(StablePtr Mailbox),
    rwStopped :: !(TVar Bool),
    rwQueue :: !(TQueue Pending),
    rwWorker :: !(Async.Async (WasmExit, Maybe ByteString))
  }

-- | Host calls are serviced on an Effectful thread through a mailbox. The FFI
-- callback copies bytes only; it cannot throw a Haskell exception through C or
-- retain a guest pointer. Nothing requests a trap after a host control decision.
runWasm :: (Concurrent :> es, IOE :> es) => WasmLimits -> ByteString -> (ByteString -> Eff es (Maybe ByteString)) -> Eff es WasmExit
runWasm limits binary dispatch = fst <$> runWasmWithInput limits binary Nothing dispatch

-- | Optional immutable input enables the data ABI. One bounded output survives
-- a later guest trap; neither channel can dispatch tools or manufacture control.
runWasmWithInput :: (Concurrent :> es, IOE :> es) => WasmLimits -> ByteString -> Maybe ByteString -> (ByteString -> Eff es (Maybe ByteString)) -> Eff es (WasmExit, Maybe ByteString)
runWasmWithInput limits binary input dispatch
  | limits.wlFuel == 0 || limits.wlMemoryBytes <= 0 || limits.wlTimeoutMicros <= 0 || limits.wlModuleBytes <= 0 || limits.wlHostCalls <= 0 = invalid "invalid host resource limits"
  | BS.length binary > limits.wlModuleBytes = invalid "module exceeds host size limit"
  | maybe False ((> 1024 * 1024) . BS.length) input = invalid "input exceeds host size limit"
  | otherwise = bracket (liftIO acquire) (liftIO . release) $ \running -> do
      result <- race (threadDelay limits.wlTimeoutMicros) (drive 0 running)
      pure (fromRight (WasmTimedOut, Nothing) result)
  where
    invalid detail = pure (WasmTrapped detail, Nothing)
    acquire = Exception.mask $ \restore -> do
      queue <- newTQueueIO
      stopped <- newTVarIO False
      handle <- wasmNew
      when (handle == nullPtr) $ Exception.throwIO (userError "could not allocate Wasmtime engine")
      callback <- newStablePtr (Mailbox queue stopped) `Exception.onException` wasmDelete handle
      worker <- Async.async (restore (run handle callback)) `Exception.onException` (freeStablePtr callback >> wasmDelete handle)
      pure (RunningWasm handle callback stopped queue worker)
    -- The safe FFI call cannot be killed with throwTo. Wake callbacks and trap
    -- guest computation, then join before releasing their C resources. This
    -- cleanup cannot be abandoned by a second cancellation.
    release running = Exception.uninterruptibleMask_ $ do
      atomically (writeTVar running.rwStopped True)
      wasmInterrupt running.rwHandle
      void (Async.waitCatch running.rwWorker)
      freeStablePtr running.rwCallback
      wasmDelete running.rwHandle
    run handle callback =
      BS.useAsCStringLen binary $ \(bytes, size) -> allocaBytes 4096 $ \message ->
        withInput $ \inputBytes inputSize -> alloca $ \outputPtr -> alloca $ \outputSize -> do
          code <- wasmRun handle (castPtr bytes) (fromIntegral size) limits.wlFuel limits.wlMemoryBytes inputBytes inputSize outputPtr outputSize callbackPointer callback message 4096
          buffer <- peek outputPtr
          output <-
            if buffer == nullPtr
              then pure Nothing
              else do
                len <- peek outputSize
                Just <$> (BS.packCStringLen (castPtr buffer, fromIntegral len) `Exception.finally` wasmFree buffer)
          exit <- if code == 0 then pure WasmCompleted else WasmTrapped <$> readDiagnostic message
          pure (exit, output)
    withInput action = case input of
      Nothing -> action nullPtr 0
      Just value -> BS.useAsCStringLen value $ \(bytes, size) -> action (castPtr bytes) (fromIntegral size)
    drive count running = do
      next <-
        liftIO . atomically $
          (Left <$> Async.waitCatchSTM running.rwWorker) `orElse` (Right <$> readTQueue running.rwQueue)
      case next of
        Left result -> either throwIO pure result
        Right (Pending request response)
          | count >= limits.wlHostCalls -> invalid "host call limit exceeded"
          | otherwise -> do
              value <- dispatch request
              liftIO . atomically $ putTMVar response value
              drive (count + 1) running

-- Static foreign export avoids allocating executable libffi trampolines.
-- Its only dynamic state is a scoped StablePtr to the mailbox, freed after join.
dispatchCallback :: ToolCallback
dispatchCallback stable bytes size output capacity =
  Exception.handle (\(_ :: Exception.SomeException) -> pure (-1)) $ do
    Mailbox queue stopped <- deRefStablePtr stable
    request <- BS.packCStringLen (castPtr bytes, fromIntegral size)
    reply <- newEmptyTMVarIO
    atomically (writeTQueue queue (Pending request reply))
    response <-
      atomically $
        (readTVar stopped >>= check >> pure Nothing) `orElse` takeTMVar reply
    case response of
      Just value | BS.length value <= fromIntegral capacity && BS.length value <= 65536 ->
        BS.useAsCStringLen value $ \(payload, len) -> do
          copyBytes output (castPtr payload) len
          pure (fromIntegral len)
      _ -> pure (-1)

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
