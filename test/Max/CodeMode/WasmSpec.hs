module Max.CodeMode.WasmSpec (spec) where

import Control.Concurrent.Async qualified as Async
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Effectful (liftIO, runEff)
import ExecutionFixture
import Max.CodeMode.Wasm
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = describe "poll-driven Wasmtime boundary" $ do
  it "retains the store between steps and delivers one completion at a time" $ do
    binary <- guestCalls [object ["tool" .= ("echo" :: Text), "args" .= object []], object ["tool" .= ("echo" :: Text), "args" .= object []]] ""
    runEff $ withGuest defaultWasmLimits binary "{}" $ \guest initial -> liftIO $ do
      initial `shouldBe` GuestCalls [GuestCall 1 "echo" (object [])] [] 1
      resumeGuest guest [(1, Null)] `shouldReturn` GuestCalls [GuestCall 2 "echo" (object [])] [] 1
      resumeGuest guest [(2, Null)] `shouldReturn` GuestDone Null

  it "rejects resume after completion, failed admission, and scope release" $ do
    binary <- guestCalls [] ""
    guest <- runEff $ withGuest defaultWasmLimits binary "{}" $ \guest initial -> do
      liftIO (initial `shouldBe` GuestDone Null)
      liftIO (resumeGuest guest [] >>= (`shouldSatisfy` trapped))
      pure guest
    resumeGuest guest [] >>= (`shouldSatisfy` trapped)
    runEff $ withGuest defaultWasmLimits {wlFuel = 0} binary "{}" $ \invalid _ ->
      liftIO (resumeGuest invalid [] >>= (`shouldSatisfy` trapped))

  it "copies Unicode outcomes through the input channel" $ do
    binary <- compileWat "(module (import \"max_v1\" \"input_size\" (func $size (result i32))) (import \"max_v1\" \"input_read\" (func $read (param i32 i32 i32) (result i32))) (import \"max_v1\" \"output_write\" (func $write (param i32 i32))) (memory (export \"memory\") 1) (func (export \"start\") (drop (call $read (i32.const 0) (i32.const 0) (call $size))) (call $write (i32.const 0) (call $size))))"
    runEff (withGuest defaultWasmLimits binary (TE.encodeUtf8 "{\"done\":\"中文😀\"}") (\_ -> pure)) `shouldReturn` GuestDone (String "中文😀")

  it "rejects old callbacks, ambient imports and invalid entry signatures" $ do
    modules <-
      traverse
        compileWat
        [ "(module (import \"max_v1\" \"tool_call\" (func)))",
          "(module (import \"wasi_snapshot_preview1\" \"proc_exit\" (func (param i32))))",
          "(module (func (export \"start\") (param i32)))",
          "(module (global (export \"start\") i32 (i32.const 0)))",
          "(module)"
        ]
    forM_ ("invalid" : modules) $ \binary ->
      runEff (withGuest defaultWasmLimits binary "{}" (\_ -> pure)) >>= (`shouldSatisfy` trapped)

  it "checks negative and overflowing data ranges" $ do
    forM_ ["(i32.const -1) (i32.const 1)", "(i32.const 65530) (i32.const 16)", "(i32.const 0) (i32.const -1)"] $ \args -> do
      binary <- compileWat ("(module (import \"max_v1\" \"output_write\" (func $write (param i32 i32))) (memory (export \"memory\") 1) (func (export \"start\") (call $write " <> args <> ")))")
      runEff (withGuest defaultWasmLimits binary "{}" (\_ -> pure)) >>= (`shouldSatisfy` trapped)

  it "rejects a second output and channel use during instantiation" $ do
    forM_ ["(func (export \"start\") (call $emit) (call $emit))", "(start $emit) (func (export \"start\"))"] $ \entry -> do
      binary <- compileWat ("(module (import \"max_v1\" \"output_write\" (func $write (param i32 i32))) (memory (export \"memory\") 1) (func $emit (call $write (i32.const 0) (i32.const 1))) " <> entry <> ")")
      runEff (withGuest defaultWasmLimits binary "{}" (\_ -> pure)) >>= (`shouldSatisfy` trapped)

  it "enforces store memory and input limits before guest effects" $ do
    binary <- compileWat "(module (memory 3) (func (export \"start\")))"
    runEff (withGuest defaultWasmLimits {wlMemoryBytes = 131072} binary "{}" (\_ -> pure)) >>= (`shouldSatisfy` trapped)
    runEff (withGuest defaultWasmLimits binary (BS.replicate (1024 * 1024 + 1) 32) (\_ -> pure)) >>= (`shouldSatisfy` trapped)

  it "stops computation by total fuel and independently by step deadline" $ do
    binary <- compileWat "(module (func (export \"start\") (loop br 0)))"
    runEff (withGuest defaultWasmLimits {wlFuel = 100} binary "{}" (\_ -> pure)) >>= (`shouldSatisfy` trapped)
    timeout 3000000 (runEff (withGuest defaultWasmLimits {wlFuel = maxBound, wlTimeoutMicros = 20000} binary "{}" (\_ -> pure))) `shouldReturn` Just (GuestTrap WasmTimedOut)

  it "interrupts and joins a running safe FFI step before freeing its store" $ do
    binary <- compileWat "(module (func (export \"start\") (loop br 0)))"
    worker <- Async.async (runEff (withGuest defaultWasmLimits {wlFuel = maxBound} binary "{}" (\_ -> pure)))
    timeout 3000000 (Async.cancel worker) `shouldReturn` Just ()
  where
    trapped GuestTrap {} = True
    trapped _ = False
