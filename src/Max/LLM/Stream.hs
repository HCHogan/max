-- |
-- Server-sent events, and the two ways a completion arrives over them.
--
-- Kept pure and separate from the HTTP call so the fiddly part — the
-- part where a wrong guess silently truncates somebody's reply — is
-- testable against recorded wire bytes instead of a live provider.
--
-- == Framing
--
-- 'sseFrames' is incremental: bytes arrive in whatever sizes the socket
-- hands over, so it returns the frames it could complete plus the
-- leftover to prepend next time.  Per the SSE spec a frame ends at a
-- blank line, repeated @data:@ lines within one frame concatenate with
-- newlines, and one optional space after the colon is not part of the
-- value.  @event:@ lines are read but unused: Anthropic repeats the
-- event name inside the payload's @type@ field, and dispatching on the
-- payload means one less thing that has to agree.
--
-- == Assembly
--
-- Both protocols deliver a tool call in pieces — the name and id in one
-- frame, then its arguments as JSON *text fragments* across many more
-- (@{\"lo@, @cation\\\": \\\"Bei@, …).  So arguments accumulate as text
-- and are parsed once at the end; a fragment is not valid JSON and
-- parsing eagerly would throw away every call with a non-trivial
-- argument.
module Max.LLM.Stream
  ( -- * Framing
    sseFrames,

    -- * Accumulation
    StreamAcc (..),
    emptyAcc,
    stepOpenAI,
    stepAnthropic,
    accToolCalls,
    PartialCall (..),
  )
where

import Data.Aeson (FromJSON, Key, Value (..), decodeStrict', withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

--------------------------------------------------------------------------------
-- Framing

-- | Split a byte stream into complete SSE frames, returning the
-- unconsumed tail.
--
-- A frame is the payload of its @data:@ field(s).  Comment lines
-- (@:@-prefixed keep-alives, which several providers send) and frames
-- with no @data:@ at all produce nothing rather than an empty payload,
-- so a keep-alive can't be mistaken for content.
sseFrames :: ByteString -> ([ByteString], ByteString)
sseFrames input = go [] (normaliseEol input)
  where
    go acc buf = case breakFrame buf of
      Nothing -> (reverse acc, buf)
      Just (frame, rest) -> case frameData frame of
        Nothing -> go acc rest
        Just d -> go (d : acc) rest

    -- A frame ends at a blank line.
    breakFrame buf =
      let (before, after) = BC.breakSubstring "\n\n" buf
       in if BC.null after
            then Nothing
            else Just (before, BC.drop 2 after)

    frameData frame =
      case [stripField l | l <- BC.lines frame, "data:" `BC.isPrefixOf` l] of
        [] -> Nothing
        ds -> Just (BC.intercalate "\n" ds)

    -- One optional space after the colon belongs to the framing, not
    -- the value.
    stripField l =
      let v = BC.drop 5 l
       in fromMaybe v (BC.stripPrefix " " v)

-- | CRLF is legal in SSE and at least one gateway sends it; normalising
-- once here keeps every downstream check single-newline.
normaliseEol :: ByteString -> ByteString
normaliseEol b
  | "\r" `BC.isInfixOf` b = BC.filter (/= '\r') b
  | otherwise = b

--------------------------------------------------------------------------------
-- Accumulation

-- | A tool call being assembled.  Arguments are raw JSON text because
-- that is how they arrive: in fragments that are individually invalid.
data PartialCall = PartialCall
  { pcId :: !Text,
    pcName :: !Text,
    pcArgs :: !Text
  }
  deriving stock (Show, Eq)

-- | What the stream has produced so far.
data StreamAcc = StreamAcc
  { -- | Assistant text, in order.
    saText :: !Text,
    -- | Tool calls by their wire index, so out-of-order fragments still
    -- land on the right call.
    saCalls :: !(Map Int PartialCall),
    -- | Reported once the provider says so; absent when it never does,
    -- which several OpenAI-compatible gateways don't unless asked.
    saPromptTokens :: !(Maybe Int),
    saCompletionTokens :: !(Maybe Int),
    saCachedTokens :: !(Maybe Int),
    -- | The provider said the message is finished.  Distinguishes a
    -- clean end from a socket that simply stopped — which is the whole
    -- point, since one gets a reply and the other gets an interruption
    -- marker.
    saDone :: !Bool
  }
  deriving stock (Show, Eq)

emptyAcc :: StreamAcc
emptyAcc =
  StreamAcc
    { saText = "",
      saCalls = Map.empty,
      saPromptTokens = Nothing,
      saCompletionTokens = Nothing,
      saCachedTokens = Nothing,
      saDone = False
    }

-- | Completed calls in wire order.
accToolCalls :: StreamAcc -> [PartialCall]
accToolCalls acc = map snd (sortOn fst (Map.toList acc.saCalls))

--------------------------------------------------------------------------------
-- OpenAI

-- | Apply one @data:@ payload from an OpenAI-compatible stream.
--
-- Unparseable payloads are ignored rather than fatal: gateways
-- interleave their own keep-alive and metadata objects, and dropping
-- the reply because one of them was unfamiliar would be the wrong
-- trade.
stepOpenAI :: ByteString -> StreamAcc -> StreamAcc
stepOpenAI payload acc
  | payload == "[DONE]" = acc {saDone = True}
  | otherwise = case decodeStrict' payload of
      Nothing -> acc
      Just v -> applyUsage v (applyChoice v acc)
  where
    applyChoice v a = case fld "choices" v :: Maybe [Value] of
      Just (choice : _) -> applyFinish choice (applyDelta choice a)
      _ -> a

    applyDelta choice a = case fld "delta" choice of
      Nothing -> a
      Just delta ->
        let withText = case fld "content" delta of
              Just (String t) -> a {saText = a.saText <> t}
              _ -> a
         in case fld "tool_calls" delta :: Maybe [Value] of
              Just calls -> foldl (flip mergeCall) withText calls
              Nothing -> withText

    -- finish_reason marks the end of the message.  Some gateways then
    -- send a usage-only frame and never a [DONE]; treating the finish
    -- as done means those still count as a clean end.
    applyFinish choice a = case fld "finish_reason" choice of
      Just (String r) | not (T.null r) -> a {saDone = True}
      _ -> a

    applyUsage v a = case fld "usage" v of
      Nothing -> a
      Just usage ->
        a
          { saPromptTokens = fld "prompt_tokens" usage <|>? a.saPromptTokens,
            saCompletionTokens = fld "completion_tokens" usage <|>? a.saCompletionTokens,
            saCachedTokens =
              (fld "prompt_tokens_details" usage >>= fld "cached_tokens")
                <|>? a.saCachedTokens
          }

-- | Fold one @tool_calls@ entry into the accumulator.  The first
-- fragment for an index carries id and name; later ones carry only more
-- argument text.
mergeCall :: Value -> StreamAcc -> StreamAcc
mergeCall v acc = case fld "index" v of
  Nothing -> acc
  Just idx ->
    let fn = fld "function" v :: Maybe Value
        prev = Map.findWithDefault (PartialCall "" "" "") idx acc.saCalls
        merged =
          PartialCall
            { pcId = fromMaybe prev.pcId (fld "id" v),
              pcName = fromMaybe prev.pcName (fn >>= fld "name"),
              pcArgs = prev.pcArgs <> fromMaybe "" (fn >>= fld "arguments")
            }
     in acc {saCalls = Map.insert idx merged acc.saCalls}

--------------------------------------------------------------------------------
-- Anthropic

-- | Apply one @data:@ payload from an Anthropic stream.
--
-- Dispatches on the payload's own @type@ rather than the @event:@ line,
-- so the framing and the body can't disagree.
stepAnthropic :: ByteString -> StreamAcc -> StreamAcc
stepAnthropic payload acc = case decodeStrict' payload of
  Nothing -> acc
  Just v -> case fld "type" v :: Maybe Text of
    Just "content_block_start" -> startBlock v acc
    Just "content_block_delta" -> deltaBlock v acc
    Just "message_start" -> messageStart v acc
    Just "message_delta" -> messageDelta v acc
    Just "message_stop" -> acc {saDone = True}
    _ -> acc
  where
    startBlock v a = fromMaybe a $ do
      idx <- fld "index" v
      block <- fld "content_block" v
      case fld "type" block :: Maybe Text of
        Just "tool_use" -> do
          cid <- fld "id" block
          nm <- fld "name" block
          pure a {saCalls = Map.insert idx (PartialCall cid nm "") a.saCalls}
        _ -> pure a

    deltaBlock v a = fromMaybe a $ do
      idx <- fld "index" v
      delta <- fld "delta" v
      case fld "type" delta :: Maybe Text of
        Just "text_delta" -> do
          t <- fld "text" delta
          pure a {saText = a.saText <> t}
        Just "input_json_delta" -> do
          frag <- fld "partial_json" delta
          let prev = Map.findWithDefault (PartialCall "" "" "") idx a.saCalls
          pure a {saCalls = Map.insert idx prev {pcArgs = prev.pcArgs <> frag} a.saCalls}
        _ -> pure a

    -- Anthropic splits usage across the first and last frames: input
    -- (with its cache breakdown) up front, output at the end.
    messageStart v a = fromMaybe a $ do
      usage <- fld "message" v >>= fld "usage"
      pure
        a
          { saPromptTokens = fld "input_tokens" usage <|>? a.saPromptTokens,
            saCachedTokens = fld "cache_read_input_tokens" usage <|>? a.saCachedTokens
          }

    messageDelta v a = fromMaybe a $ do
      usage <- fld "usage" v
      pure a {saCompletionTokens = fld "output_tokens" usage <|>? a.saCompletionTokens}

--------------------------------------------------------------------------------

-- | Read one field of a JSON object, giving 'Nothing' for a non-object,
-- a missing key, or a value of the wrong shape.  Every provider sends
-- fields we don't model and omits ones we do, so total accessors keep
-- the reducers readable.
fld :: FromJSON a => Key -> Value -> Maybe a
fld k = parseMaybe (withObject "obj" (.: k))

-- | First 'Just' wins, keeping an earlier reading when a later frame
-- omits the field.
(<|>?) :: Maybe a -> Maybe a -> Maybe a
Just x <|>? _ = Just x
Nothing <|>? y = y

infixl 3 <|>?
