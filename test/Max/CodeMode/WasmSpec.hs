module Max.CodeMode.WasmSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async qualified as Async
import Control.Exception (finally)
import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.String (fromString)
import Data.Text (Text)
import Effectful (liftIO, runEff)
import Effectful.Concurrent (runConcurrent, threadDelay)
import ExecutionFixture
import Max.CodeMode.Wasm
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "embedded Wasmtime boundary" $ do
  it "keeps input/output separate from tool dispatch and preserves output after a trap" $ do
    binary <- compileWat "(module (import \"max_v1\" \"input_read\" (func $read (param i32 i32 i32) (result i32))) (import \"max_v1\" \"output_write\" (func $write (param i32 i32))) (memory (export \"memory\") 1) (func (export \"_start\") (drop (call $read (i32.const 0) (i32.const 0) (i32.const 2))) (call $write (i32.const 0) (i32.const 2)) unreachable))"
    result <- runEff . runConcurrent $ runWasmWithInput defaultWasmLimits binary (Just "{}") (\_ -> liftIO (fail "data channel dispatched a tool"))
    fst result `shouldSatisfy` trapped
    snd result `shouldBe` Just "{}"
    runEff (runConcurrent (runWasm defaultWasmLimits binary (\_ -> pure Nothing))) >>= (`shouldSatisfy` trapped)

  it "rejects invalid data ranges and a second output without replacing the first" $ do
    forM_
      [ "(call $write (i32.const -1) (i32.const 1))",
        "(call $write (i32.const 0) (i32.const 65537))",
        "(drop (call $read (i32.const 1) (i32.const 0) (i32.const 2)))"
      ]
      $ \body -> do
        binary <- compileWat ("(module (import \"max_v1\" \"input_read\" (func $read (param i32 i32 i32) (result i32))) (import \"max_v1\" \"output_write\" (func $write (param i32 i32))) (memory (export \"memory\") 2) (func (export \"_start\") " <> body <> "))")
        result <- runEff . runConcurrent $ runWasmWithInput defaultWasmLimits binary (Just "{}") (\_ -> pure Nothing)
        fst result `shouldSatisfy` trapped
        snd result `shouldBe` Nothing
    binary <- compileWat "(module (import \"max_v1\" \"output_write\" (func $write (param i32 i32))) (memory (export \"memory\") 1) (data (i32.const 0) \"12\") (func (export \"_start\") (call $write (i32.const 0) (i32.const 1)) (call $write (i32.const 1) (i32.const 1))))"
    result <- runEff . runConcurrent $ runWasmWithInput defaultWasmLimits binary (Just "{}") (\_ -> pure Nothing)
    fst result `shouldSatisfy` trapped
    snd result `shouldBe` Just "1"

  it "copies UTF-8 requests and replies through the host mailbox" $ do
    seen <- newIORef []
    binary <- guestCalls [object ["tool" .= ("echo" :: Text), "args" .= object ["value" .= (7 :: Int)]]] "(if (i32.ne (i32.load8_u (i32.const 65536)) (i32.const 123)) (then unreachable))"
    result <- runEff . runConcurrent $ runWasm defaultWasmLimits binary $ \bytes -> do
      liftIO (modifyIORef' seen (bytes :))
      pure (Just "{\"ok\":true}")
    result `shouldBe` WasmCompleted
    length <$> readIORef seen `shouldReturn` 1

  it "rejects unknown imports, invalid binaries and invalid entry signatures" $ do
    modules <-
      traverse
        compileWat
        [ "(module (import \"wasi_snapshot_preview1\" \"proc_exit\" (func (param i32))) (func (export \"_start\")))",
          "(module (func (export \"_start\") (param i32)))",
          "(module (global (export \"_start\") i32 (i32.const 0)))",
          "(module)"
        ]
    forM_ ("invalid" : modules) $ \binary ->
      runEff (runConcurrent (runWasm defaultWasmLimits binary (\_ -> liftIO (fail "host effect escaped")))) >>= (`shouldSatisfy` trapped)

  it "checks both memory ranges before dispatch including negative and overflowing offsets" $ do
    forM_ ["-1 10 65536 32", "131070 10 65536 32", "0 65537 65536 32", "0 10 131070 32", "0 10 0 -1", "0 10 0 0"] $ \args -> do
      let constants = foldMap (\word -> "(i32.const " <> word <> ")") (words args)
      binary <- compileWat ("(module (import \"max_v1\" \"tool_call\" (func $f (param i32 i32 i32 i32) (result i32))) (memory (export \"memory\") 2) (func (export \"_start\") (drop (call $f " <> fromString constants <> "))))")
      runEff (runConcurrent (runWasm defaultWasmLimits binary (\_ -> liftIO (fail "invalid range dispatched")))) >>= (`shouldSatisfy` trapped)

  it "traps oversized replies without calling the host twice" $ do
    seen <- newIORef (0 :: Int)
    binary <- guestCalls [object []] ""
    result <- runEff . runConcurrent $ runWasm defaultWasmLimits binary $ \_ -> do
      liftIO (modifyIORef' seen (+ 1))
      pure (Just (BS.replicate 65537 65))
    result `shouldSatisfy` trapped
    readIORef seen `shouldReturn` 1

  it "bounds host imports even when their arguments are invalid or calls are free" $ do
    binary <- guestCalls [object [], object []] ""
    seen <- newIORef (0 :: Int)
    result <- runEff . runConcurrent $ runWasm defaultWasmLimits {wlHostCalls = 1} binary $ \_ -> do
      liftIO (modifyIORef' seen (+ 1))
      pure (Just "{}")
    result `shouldBe` WasmTrapped "host call limit exceeded"
    readIORef seen `shouldReturn` 1

  it "enforces initial memory limits and prevents growth beyond the limit" $ do
    tooLarge <- compileWat "(module (memory 3) (func (export \"_start\")))"
    growth <- compileWat "(module (memory 2) (func (export \"_start\") (if (i32.ne (memory.grow (i32.const 1)) (i32.const -1)) (then unreachable))))"
    let limits = defaultWasmLimits {wlMemoryBytes = 131072}
    runEff (runConcurrent (runWasm limits tooLarge (\_ -> pure Nothing))) >>= (`shouldSatisfy` trapped)
    runEff (runConcurrent (runWasm limits growth (\_ -> pure Nothing))) `shouldReturn` WasmCompleted

  it "stops computation by fuel and independently by epoch deadline" $ do
    binary <- compileWat "(module (func (export \"_start\") (loop br 0)))"
    runEff (runConcurrent (runWasm defaultWasmLimits {wlFuel = 100} binary (\_ -> pure Nothing))) >>= (`shouldSatisfy` trapped)
    timeout 3000000 (runEff (runConcurrent (runWasm defaultWasmLimits {wlFuel = maxBound, wlTimeoutMicros = 20000} binary (\_ -> pure Nothing)))) `shouldReturn` Just WasmTimedOut

  it "cancels pending host IO and joins the FFI worker without leaking callbacks" $ do
    entered <- newEmptyMVar
    ended <- newEmptyMVar
    blocked <- newEmptyMVar
    binary <- guestCalls [object []] ""
    let run = runEff . runConcurrent $ runWasm defaultWasmLimits binary $ \_ ->
          liftIO ((putMVar entered () >> takeMVar blocked >> pure Nothing) `finally` putMVar ended ())
    -- Host blocks on a separate MVar after announcing entry; cancellation must
    -- run its finalizer while the C callback is waiting on the mailbox reply.
    worker <- Async.async run
    takeMVar entered
    timeout 3000000 (Async.cancel worker) `shouldReturn` Just ()
    timeout 1000000 (takeMVar ended) `shouldReturn` Just ()

  it "expires while a host action is blocked" $ do
    binary <- guestCalls [object []] ""
    result <- runEff . runConcurrent $ runWasm defaultWasmLimits {wlTimeoutMicros = 20000} binary (\_ -> threadDelay 3000000 >> pure Nothing)
    result `shouldBe` WasmTimedOut
  where
    trapped WasmTrapped {} = True
    trapped _ = False
