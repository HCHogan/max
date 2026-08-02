-- |
-- Deterministic token accounting and decision traces shared by context
-- collection, policy, rendering, and future episode materialization.
--
-- The estimator is intentionally conservative and provider-neutral.  It is a
-- safety/planning boundary, not an attempt to reproduce every proprietary
-- tokenizer.  Provider-reported usage can later calibrate it without changing
-- the pure planning interface.
module Max.Context
  ( ContextBudget (..),
    ContextDecision (..),
    ContextTrace (..),
    contextBudget,
    estimateTextTokens,
    estimateMessageTokens,
    estimateMessagesTokens,
  )
where

import Data.Aeson (encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Effects.LLM (ChatMessage (..), ContentBlock (..), ToolCall (..))
import Max.ModelCatalog (ContextLimits (..), contextInputBudget)

-- | Reserves resolved for one concrete prompt.  Attachment reserve is applied
-- only when the prompt actually contains attached image/video blocks.
data ContextBudget = ContextBudget
  { cbMaxInputTokens :: !Int,
    cbPromptTokenLimit :: !Int,
    cbReservedOutputTokens :: !Int,
    cbAttachmentReserve :: !Int,
    cbToolRoundReserve :: !Int
  }
  deriving stock (Show, Eq)

data ContextDecision
  = ContextIncluded
  | ContextDropped
  | ContextReserved
  | ContextOverBudget
  deriving stock (Show, Eq)

-- | One explainable planning decision.  Sources are stable machine-readable
-- names so the same values can later be persisted and shown in admin traces.
data ContextTrace = ContextTrace
  { ctSource :: !Text,
    ctEstimatedTokens :: !Int,
    ctDecision :: !ContextDecision,
    ctReason :: !Text
  }
  deriving stock (Show, Eq)

contextBudget :: ContextLimits -> Bool -> ContextBudget
contextBudget limits hasAttachments =
  ContextBudget
    { cbMaxInputTokens = limits.maxInputTokens,
      cbPromptTokenLimit = contextInputBudget limits hasAttachments,
      cbReservedOutputTokens = limits.reservedOutputTokens,
      cbAttachmentReserve = if hasAttachments then limits.attachmentReserve else 0,
      cbToolRoundReserve = limits.toolRoundReserve
    }

-- | Conservative tokenizer-independent text estimate.  The larger of three
-- UTF-8 bytes per token and two Unicode codepoints per token slightly
-- overestimates ordinary prose while treating most CJK codepoints as one
-- token.  Empty strings cost no content tokens; message framing is accounted
-- separately.
estimateTextTokens :: Text -> Int
estimateTextTokens content
  | BS.null bytes = 0
  | otherwise = max ((BS.length bytes + 2) `div` 3) ((lengthInCodepoints + 1) `div` 2)
  where
    bytes = TE.encodeUtf8 content
    lengthInCodepoints = T.length content

estimateMessageTokens :: ChatMessage -> Int
estimateMessageTokens message =
  messageOverhead + case message of
    MsgSystem content -> estimateTextTokens content
    MsgUser content -> estimateTextTokens content
    MsgUserBlocks blocks -> sum (map estimateBlockTokens blocks)
    MsgAssistant content -> estimateTextTokens content
    MsgAssistantToolCalls raw calls ->
      estimateLazyBytesTokens (encode raw)
        + sum
          [ estimateTextTokens call.callId
              + estimateTextTokens call.callName
              + estimateLazyBytesTokens (encode call.callArguments)
          | call <- calls
          ]
    MsgTool callId content -> estimateTextTokens callId + estimateTextTokens content
  where
    -- Role/envelope/separator allowance across OpenAI, Responses, and
    -- Anthropic wire shapes.
    messageOverhead = 8

estimateMessagesTokens :: [ChatMessage] -> Int
estimateMessagesTokens messages = 4 + sum (map estimateMessageTokens messages)

estimateBlockTokens :: ContentBlock -> Int
estimateBlockTokens = \case
  TextBlock content -> estimateTextTokens content + 2
  -- Binary payloads are represented by the attachment reserve, not by treating
  -- base64 bytes as language tokens.
  ImageDataUrl _ -> 0
  VideoDataUrl _ -> 0

estimateLazyBytesTokens :: LBS.ByteString -> Int
estimateLazyBytesTokens bytes
  | LBS.null bytes = 0
  | otherwise = fromIntegral ((LBS.length bytes + 1) `div` 2)
