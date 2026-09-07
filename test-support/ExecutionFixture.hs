module ExecutionFixture (compileWat, guestProgram, guestCalls, echoDefinition, echoTool, noJournal) where

import Data.Aeson (Value, encode, object, (.=))
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
  "(module (import \"max_v1\" \"tool_call\" (func $call (param i32 i32 i32 i32) (result i32)))\n"
    <> "(memory (export \"memory\") 2)\n"
    <> T.concat ["(data (i32.const " <> number offset <> ") \"" <> escape bytes <> "\")\n" | (offset, bytes) <- entries]
    <> "(func (export \"_start\")\n"
    <> T.concat ["(drop (call $call (i32.const " <> number offset <> ") (i32.const " <> number (BS.length bytes) <> ") (i32.const 65536) (i32.const 65536)))\n" | (offset, bytes) <- entries]
    <> after
    <> "))"
  where
    entries = zip [0, 4096 ..] (map (LBS.toStrict . encode) requests)
    number = T.pack . show
    escape = T.pack . concatMap (\byte -> let h = showHex byte "" in '\\' : (if length h == 1 then '0' : h else h)) . BS.unpack

echoDefinition :: ToolDefinition
echoDefinition = ToolDefinition (ToolRef "echo") (SchemaVersion 1) (Set.singleton (EffectRead "test")) ParallelSafe RetrySafe (Set.singleton CurrentConversation) (ToolDeadline 30) True WorkCall

echoTool :: Tool es
echoTool = Tool "echo" "echo" (object ["type" .= ("object" :: Text), "required" .= (["value"] :: [Text]), "properties" .= object ["value" .= object ["type" .= ("integer" :: Text)]]]) (pure . Right)

noJournal :: ExecutionHooks es
noJournal = ExecutionHooks (pure ()) (\_ _ -> pure Nothing) (\_ _ -> pure ()) (\_ _ -> pure ())
