{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

import Control.Monad (forM_, unless)
import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as BL
import Data.Text qualified as T
import Max.Browser.View
import Max.Effects.Agent (toolResultMessage)
import Max.Effects.LLM (ChatMessage (..), ToolCall (..))
import Max.MCP.Client (mcpTextContent)
import System.Environment (getArgs)

main :: IO ()
main = do
  [path] <- getArgs
  samples <- BL.readFile path >>= either fail pure . eitherDecode
  forM_ (samples :: [Value]) $ \sample -> do
    (action, request, raw) <- either fail pure $ parseEither (withObject "sample" $ \o -> (,,) <$> o .: "action" <*> o .: "request" <*> o .: "raw") sample
    let budget = browserBudget action request
    case browserView budget action raw of
      String text -> do
        unless (T.length text <= budget.maxChars) (fail "result exceeds declared character budget")
        case toolResultMessage (ToolCall "acceptance" "browser" request) (Right (String text)) of
          MsgTool _ message -> unless (message == text && T.length message <= budget.maxChars) (fail "model message changed the projection or exceeded its budget")
          _ -> fail "expected a model tool message"
        putStrLn ("PASS " <> T.unpack action <> ": raw=" <> show (T.length (mcpTextContent raw)) <> " projected=" <> show (T.length text) <> " budget=" <> show budget.maxChars)
      _ -> fail "browser result was not compact text"
