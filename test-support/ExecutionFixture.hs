module ExecutionFixture (compileWat, guestProgram, guestCalls, echoDefinition, echoTool, noJournal) where

import Control.Concurrent.STM (retry)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.CodeMode.Wasm (watToWasm)
import Max.Effects.Tools
import Max.Execution.Tools (ExecutionHooks (..))
import Numeric (showHex)

compileWat :: Text -> IO ByteString
compileWat source = watToWasm (TE.encodeUtf8 source) >>= either (fail . T.unpack) pure

guestCalls :: [Value] -> Text -> IO ByteString
guestCalls requests after = compileWat (guestProgram requests after)

guestProgram :: [Value] -> Text -> Text
guestProgram requests after =
  "(module (import \"max_v1\" \"output_write\" (func $write (param i32 i32)))\n"
    <> "(memory (export \"memory\") 2) (global $step (mut i32) (i32.const 0))\n"
    <> T.concat ["(data (i32.const " <> number offset <> ") \"" <> escape bytes <> "\")\n" | (offset, bytes) <- entries]
    <> "(func $step (local $n i32) (local.set $n (global.get $step)) (global.set $step (i32.add (local.get $n) (i32.const 1)))\n"
    <> T.concat ["(if (i32.eq (local.get $n) (i32.const " <> number index <> ")) (then (call $write (i32.const " <> number offset <> ") (i32.const " <> number (BS.length bytes) <> ")) return))\n" | (index, (offset, bytes)) <- zip [0 ..] entries]
    <> after
    <> ") (func (export \"start\") (call $step)) (func (export \"resume\") (call $step)))"
  where
    packet ident (Object fields) = object ["calls" .= [Object (KeyMap.insert "id" (toNumber ident) fields)], "waiting" .= (1 :: Int)]
    packet _ value = value
    toNumber = Number . fromIntegral
    messages = zipWith packet [1 :: Int ..] requests <> [object ["done" .= Null] | T.null after]
    entries = zip [0, 4096 ..] (map (LBS.toStrict . encode) messages)
    number = T.pack . show
    escape = T.pack . concatMap (\byte -> let h = showHex byte "" in '\\' : (if length h == 1 then '0' : h else h)) . BS.unpack

echoDefinition :: ToolDefinition
echoDefinition = ToolDefinition (ToolRef "echo") (SchemaVersion 1) (Set.singleton (EffectRead "test")) ParallelSafe RetrySafe (Set.singleton CurrentConversation) (ToolDeadline 30) True WorkCall ShortTool

echoTool :: Tool es
echoTool = legacyTool "echo" "echo" (object ["type" .= ("object" :: Text), "required" .= (["value"] :: [Text]), "properties" .= object ["value" .= object ["type" .= ("integer" :: Text)]]]) (pure . Right)

noJournal :: ExecutionHooks es
noJournal = ExecutionHooks (pure ()) (\_ _ -> pure Nothing) (\_ _ -> pure ()) (pure (Just (pure ()))) retry (pure Nothing) (\_ _ -> pure ()) (pure Nothing) (\_ -> pure Nothing) (pure (pure ()))
