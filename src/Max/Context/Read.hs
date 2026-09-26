{-# LANGUAGE DeriveAnyClass #-}

-- | Pure read requests and opaque continuation tokens. Tokens are locators,
-- not credentials: every interpreter lookup must still bind the current scope.
module Max.Context.Read
  ( ReadRequest (..),
    ReadRef (..),
    ReadCursor (..),
    ReadLane (..),
    parseReadRequest,
    parseReadRef,
    parseCanonicalId,
    encodeReadCursor,
    decodeReadCursor,
    readLink,
    messageRef,
    textFingerprint,
    takeTextTokens,
    renderReadMessage,
    renderObservationPage,
  )
where

import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone, UTCTime)
import GHC.Generics (Generic)
import Max.Context (estimateTextTokens)
import Max.Episode.Types (EpisodeHandle, parseEpisodeHandle)
import Max.History.Types (HistoryItem (..), bestName)
import Max.Time.Parse (parseTimeArg)
import Text.Read (readMaybe)

data ReadRef = MessageRef !Int64 | EpisodeRef !EpisodeHandle | MemoryRef !Int64 | ForwardRef !Int64
  deriving stock (Show, Eq)

data ReadRequest = ReadRequest
  { rrRef :: !(Maybe ReadRef),
    rrFrom :: !(Maybe UTCTime),
    rrUntil :: !(Maybe UTCTime),
    rrBefore :: !Int,
    rrAfter :: !Int,
    rrLimit :: !Int,
    rrCursor :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

data ReadLane = Timeline | Forward !Int64 | Body !Int64 !Int !Text | Observation !Int64 !Int64 !Int
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

data ReadCursor = ReadCursor
  { rcVersion :: !Int,
    rcScope :: !Int64,
    rcLane :: !ReadLane,
    rcFrom :: !(Maybe UTCTime),
    rcUntil :: !(Maybe UTCTime),
    rcEpisode :: !(Maybe Text),
    rcBackward :: !Bool,
    rcAt :: !Int64,
    rcLimit :: !Int
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

parseReadRef :: Text -> Either Text ReadRef
parseReadRef raw
  | Just value <- T.stripPrefix "message:" raw = numeric MessageRef value
  | Just value <- T.stripPrefix "forward:" raw = numeric ForwardRef value
  | Just value <- T.stripPrefix "memory:" raw = numeric MemoryRef value
  | Just value <- T.stripPrefix "episode:" raw, Just handle <- parseEpisodeHandle value = Right (EpisodeRef handle)
  | otherwise = Left "ref must be message:<id>, episode:<uuid>, memory:<id> or forward:<id>"
  where
    numeric ctor value = ctor <$> parseCanonicalId value

parseCanonicalId :: Text -> Either Text Int64
parseCanonicalId value = case readMaybe (T.unpack value) :: Maybe Integer of
  Just number | number >= toInteger (minBound :: Int64) && number <= toInteger (maxBound :: Int64) -> Right (fromInteger number)
  _ -> Left "invalid canonical id (expected signed 64-bit decimal string)"

parseReadRequest :: TimeZone -> Value -> Parser ReadRequest
parseReadRequest tz = withObject "context_read" $ \o -> do
  ref <- o .:? "ref" >>= traverse (either (fail . T.unpack) pure . parseReadRef)
  from <- time o "from"
  endTime <- time o "until"
  before <- o .:? "before" .!= 0
  after <- o .:? "after" .!= 0
  limit <- o .:? "limit" .!= 40
  cursor <- o .:? "cursor"
  unless (before >= 0 && before <= 100 && after >= 0 && after <= 100 && limit >= 1 && limit <= 100) $
    fail "before/after must be 0..100; limit must be 1..100"
  case (from, endTime) of
    (Just start, Just end) | start >= end -> fail "from must precede until (exclusive)"
    _ -> pure ()
  when (before + after > 0) $ case ref of
    Just MessageRef {} -> pure ()
    _ -> fail "before/after require a message ref"
  case cursor of
    Just _ ->
      unless (null [key | key <- ["ref", "from", "until", "before", "after", "limit"], key `elem` map fst (toListObject o)]) $
        fail "pass continuation objects unchanged; cursor cannot be combined with selectors"
    Nothing -> pure ()
  pure (ReadRequest ref from endTime before after limit cursor)
  where
    time o key = o .:? key >>= traverse (either (fail . T.unpack) pure . parseTimeArg tz)
    toListObject = KeyMap.toList

encodeReadCursor :: ReadCursor -> Text
encodeReadCursor = TE.decodeUtf8 . B64.encode . LBS.toStrict . encode

decodeReadCursor :: Int64 -> Text -> Either Text ReadCursor
decodeReadCursor scope raw = do
  when (T.length raw > 4096) (Left "invalid context cursor")
  bytes <- either (const (Left "invalid context cursor")) Right (B64.decode (TE.encodeUtf8 raw))
  cursor <- either (const (Left "invalid context cursor")) Right (eitherDecodeStrict' bytes)
  unless (cursor.rcVersion == 1 && cursor.rcScope == scope && cursor.rcLimit >= 1 && cursor.rcLimit <= 100) $
    Left "context cursor is invalid or belongs to another conversation"
  case (cursor.rcFrom, cursor.rcUntil) of
    (Just start, Just end) | start >= end -> Left "invalid context cursor range"
    _ -> pure ()
  case cursor.rcLane of
    Body _ offset _ | offset < 0 -> Left "invalid body offset"
    Observation _ batch offset | batch < 0 || offset < 0 -> Left "invalid observation cursor"
    _ -> pure ()
  pure cursor

readLink :: ReadCursor -> Value
readLink cursor = object ["cursor" .= encodeReadCursor cursor]

-- | Frozen task-local evidence is paged as text, including the original event
-- envelope. The interpreter must check both conversation and task ownership.
renderObservationPage :: ReadCursor -> Int -> Text -> Either Text Value
renderObservationPage cursor budget body = case cursor.rcLane of
  Observation owner batch offset ->
    let part = takeTextTokens (max 1 (budget - 256)) (T.drop offset body)
        end = offset + T.length part
        next = if end < T.length body then readLink cursor {rcLane = Observation owner batch end} else Null
     in Right (object ["items" .= [object ["kind" .= ("node_observation" :: Text), "text" .= part, "text_offset" .= offset, "complete" .= (end >= T.length body), "more" .= next]], "prev" .= Null, "next" .= next])
  _ -> Left "not an observation cursor"

messageRef :: Int64 -> Text
messageRef mid = "message:" <> T.pack (show mid)

textFingerprint :: Text -> Text
textFingerprint = TE.decodeUtf8 . B64.encode . SHA256.hash . TE.encodeUtf8

renderReadMessage :: ReadCursor -> Int -> Int -> HistoryItem -> UTCTime -> Maybe Text -> Bool -> Value
renderReadMessage cursor budget offset h occurred episode hasForward =
  let body = h.renderedText
      part = takeTextTokens budget (T.drop offset body)
      end = offset + T.length part
      complete = end >= T.length body
      more = if complete then Null else readLink cursor {rcLane = Body h.canonicalId end (textFingerprint body)}
   in object
        [ "kind" .= ("message" :: Text),
          "ref" .= messageRef h.canonicalId,
          "sender" .= object ["id" .= T.pack (show h.authorPrincipalId), "name" .= bestName h],
          "time" .= h.receivedAt,
          "received_at" .= h.receivedAt,
          "occurred_at" .= occurred,
          "text" .= part,
          "text_offset" .= offset,
          "complete" .= complete,
          "more" .= more,
          "reply_to" .= fmap messageRef h.replyTo,
          "episode" .= fmap ("episode:" <>) episode,
          "forward" .= (if hasForward then object ["ref" .= ("forward:" <> T.pack (show h.canonicalId))] else Null)
        ]

-- | Largest prefix fitting our conservative estimator; Unicode-safe and never
-- silently discarded. The caller provides an explicit body continuation.
takeTextTokens :: Int -> Text -> Text
takeTextTokens budget body = T.take (max 1 (go 0 (T.length body))) body
  where
    go low high
      | low >= high = low
      | estimateTextTokens (T.take mid body) <= max 1 budget = go mid high
      | otherwise = go low (mid - 1)
      where
        mid = (low + high + 1) `div` 2
