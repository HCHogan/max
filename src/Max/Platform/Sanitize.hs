module Max.Platform.Sanitize
  ( sanitizeRawPayload,
    sanitizeInboundEnvelope,
    sanitizePostgresValue,
    sanitizePostgresText,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( KeyValue ((.=)),
    Value (Array, Object, String),
    encode,
    object,
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.IR
  ( Body (Body, nodes),
    Card (..),
    Emote (..),
    ForwardRef (ForwardRef, count, nativeId),
    MediaMeta (..),
    MediaRef,
    Node (..),
    Phase (Ingest),
    Unsupported (..),
    nonBlank,
    parseMediaRef,
    renderMediaRef,
  )
import Max.Platform.Envelope
  ( InboundEnvelope (..),
  )
import Max.Platform.Types
  ( MessageRelation (..),
    NativeEventId (NativeEventId),
    NativeUserId (NativeUserId),
    PlatformCursor (PlatformCursor),
  )

sanitizeRawPayload :: Int -> Maybe Value -> (Maybe Value, Bool)
sanitizeRawPayload _ Nothing = (Nothing, False)
sanitizeRawPayload maxBytes (Just raw) =
  let sanitized = redact (sanitizePostgresValue raw)
      bytes = encode sanitized
      size = LBS.length bytes
   in if size <= fromIntegral (max 0 maxBytes)
        then (Just sanitized, False)
        else
          ( Just
              ( object
                  [ "truncated" .= True,
                    "sanitized_bytes" .= size,
                    "sha256" .= TE.decodeUtf8 (Base16.encode (SHA256.hashlazy bytes))
                  ]
              ),
            True
          )
  where
    redact = \case
      Object values -> Object (KeyMap.mapWithKey redactField values)
      Array values -> Array (fmap redact values)
      other -> other
    redactField key value
      | isSecretKey (Key.toText key) = String "[redacted]"
      | otherwise = redact value
    isSecretKey =
      (`elem` ["token", "access_token", "password", "authorization", "secret", "cookie", "admin_key"])
        . T.toLower

-- PostgreSQL text and jsonb reject U+0000 even though upstream JSON decoders
-- can represent it.  Normalize that single forbidden code point at the shared
-- ingest boundary so one malformed platform event cannot wedge a durable
-- cursor.  U+FFFD keeps the lossy position explicit instead of silently
-- deleting content.
sanitizePostgresText :: Text -> Text
sanitizePostgresText = T.map (\c -> if c == '\NUL' then '\xfffd' else c)

sanitizePostgresValue :: Value -> Value
sanitizePostgresValue = \case
  Object values ->
    Object . KeyMap.fromList $
      [ ( Key.fromText (sanitizePostgresText (Key.toText key)),
          sanitizePostgresValue value
        )
      | (key, value) <- KeyMap.toList values
      ]
  Array values -> Array (fmap sanitizePostgresValue values)
  String body -> String (sanitizePostgresText body)
  other -> other

sanitizeInboundEnvelope :: InboundEnvelope -> InboundEnvelope
sanitizeInboundEnvelope envelope =
  envelope
    { nativeEventId = sanitizeNativeEventId envelope.nativeEventId,
      senderNativeId = sanitizeNativeUserId envelope.senderNativeId,
      -- A blank display name is an absent one, not a name.  Bridges that pass
      -- one through (QQ's unset 群名片 is @""@, not a missing key) would
      -- otherwise store it, and a stored blank outranks nothing: it is what
      -- the identity row keeps and what the transcript reads back, so the
      -- prompt roster degrades to a bare principal id.
      senderDisplayName = nonBlank . sanitizePostgresText =<< envelope.senderDisplayName,
      content = Body (sanitizeIngestNode <$> envelope.content.nodes),
      relations = sanitizeRelation <$> envelope.relations,
      sourceCursor = sanitizeCursor <$> envelope.sourceCursor,
      rawPayload = sanitizePostgresValue <$> envelope.rawPayload
    }
  where
    sanitizeCursor (PlatformCursor value) = PlatformCursor (sanitizePostgresValue value)

sanitizeNativeUserId :: NativeUserId -> NativeUserId
sanitizeNativeUserId (NativeUserId native) = NativeUserId (sanitizePostgresText native)

sanitizeNativeEventId :: NativeEventId -> NativeEventId
sanitizeNativeEventId (NativeEventId native) = NativeEventId (sanitizePostgresText native)

sanitizeRelation :: MessageRelation -> MessageRelation
sanitizeRelation = \case
  ReplyTo native -> ReplyTo (sanitizeNativeEventId native)
  Replaces native -> Replaces (sanitizeNativeEventId native)
  Redacts native -> Redacts (sanitizeNativeEventId native)
  ReactsTo native reaction action ->
    ReactsTo (sanitizeNativeEventId native) (sanitizePostgresText reaction) action
  ContainedIn native position ->
    ContainedIn (sanitizeNativeEventId native) (max 0 position)

sanitizeIngestNode :: Node 'Ingest -> Node 'Ingest
sanitizeIngestNode = \case
  NText body -> NText (sanitizePostgresText body)
  NMention native display ->
    NMention (sanitizeNativeUserId native) (sanitizePostgresText display)
  NEmote emote ->
    NEmote
      Emote
        { origin = emote.origin,
          nativeId = sanitizePostgresText emote.nativeId,
          name = sanitizePostgresText <$> emote.name,
          raw = sanitizePostgresValue <$> emote.raw
        }
  NMedia source meta ->
    NMedia
      (sanitizeMediaRef <$> source)
      MediaMeta
        { kind = meta.kind,
          mime = sanitizePostgresText <$> meta.mime,
          sizeBytes = meta.sizeBytes,
          name = sanitizePostgresText <$> meta.name,
          description = sanitizePostgresText <$> meta.description,
          raw = sanitizePostgresValue <$> meta.raw
        }
  NCard card ->
    NCard
      Card
        { title = sanitizePostgresText <$> card.title,
          subtitle = sanitizePostgresText <$> card.subtitle,
          url = sanitizePostgresText <$> card.url,
          tag = sanitizePostgresText <$> card.tag,
          preview = sanitizeMediaRef <$> card.preview,
          raw = sanitizePostgresValue <$> card.raw
        }
  NForward forward ->
    NForward
      ForwardRef
        { nativeId = sanitizePostgresText forward.nativeId,
          count = forward.count
        }
  NUnsupported unsupported ->
    NUnsupported
      Unsupported
        { source = sanitizePostgresText unsupported.source,
          description = sanitizePostgresText unsupported.description,
          raw = sanitizePostgresValue <$> unsupported.raw
        }

sanitizeMediaRef :: MediaRef -> MediaRef
sanitizeMediaRef ref =
  fromMaybe
    (error "sanitizeMediaRef: validated reference became invalid")
    (parseMediaRef (sanitizePostgresText (renderMediaRef ref)))
