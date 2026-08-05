-- |
-- Outbound sticker resolution: turn a @stickers.id@ (the handle the
-- model writes as @[sticker#\<id\>]@ in its reply) into the OneBot
-- segments that resend that sticker.  This is the send half of the
-- library that "Max.DB.Stickers" ingests and "Max.Stickers" captions;
-- it used to live inside a @send_sticker@ tool, but sending is now an
-- inline placeholder the reply post-processor resolves (see
-- 'Max.Handler.sendAndPersistReply'), so the logic moved here to be
-- shared.
module Max.Sticker
  ( ResolvedSticker (..),
    resolveSticker,
  )
where

import Data.Aeson (ToJSON (toJSON), Value (Number, Object, String), object, (.=))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Database.PostgreSQL.Simple (Only (..), (:.) (..))
import Effectful
import Effectful.Exception (IOException, try)
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.IR
import Max.Platform.Types (Platform (PlatformQQ))
import OneBot.Segment (Segment (..))

data ResolvedSticker = ResolvedSticker
  { description :: !Text,
    node :: !(Node 'Ingest)
  }
  deriving stock (Eq, Show)

-- | Resolve a sticker id into the segments that resend it — an mface
-- goes back natively (animates in-client) when we still have its
-- metadata, anything else as a @sub_type=1@ image — plus the caption,
-- which the caller stores as the bot's own @[sticker#\<id\>: …]@ history
-- line.  'Left' when the id is unknown/banned or the blob can't be
-- read: the caller drops the placeholder instead of failing the reply.
-- Bumps @times_sent@ on success (the popularity signal for retrieval).
resolveSticker ::
  (Blob :> es, WithConnection :> es, IOE :> es) =>
  Int64 ->
  Eff es (Either Text ResolvedSticker)
resolveSticker sid = do
  rows <-
    query
      "SELECT s.sha256, s.kind, s.emoji_id, s.emoji_package_id, s.mface_key \
      \     , s.summary, s.description \
      \  FROM stickers s \
      \  WHERE s.id = ? AND NOT s.banned \
      \  LIMIT 1"
      (Only sid)
  case rows ::
    [ (Text, Text, Maybe Text, Maybe Text, Maybe Text)
             :. (Maybe Text, Text)
         ] of
    [] -> pure (Left ("no sticker id=" <> T.pack (show sid)))
    (((sha, kind, eid, pid, key) :. (summ, desc)) : _) ->
      buildSegs sha kind eid pid key summ >>= \case
        Left err -> pure (Left err)
        Right node -> do
          _ <-
            execute
              "UPDATE stickers SET times_sent = times_sent + 1 WHERE sha256 = ?"
              (Only sha)
          pure (Right (ResolvedSticker desc node))
  where
    buildSegs sha kind eid pid key summ = case (kind, eid, pid, key) of
      ("mface", Just e, Just p, Just k) ->
        let native =
              SegOther "mface" . Object . mkObj $
                [ ("emoji_id", String e),
                  ("emoji_package_id", numberish p),
                  ("key", String k)
                ]
                  <> [("summary", String s) | Just s <- [summ]]
         in pure . Right $
              NEmote
                Emote
                  { origin = PlatformQQ,
                    nativeId = e,
                    name = summ,
                    raw = Just (withStickerId sid (toJSON native))
                  }
      _ -> case blobRefFromSha256 sha of
        Nothing -> pure (Left "sticker blob reference is invalid")
        Just ref -> do
          ebytes <- try @IOException (readBlob ref)
          pure $ case ebytes of
            Left e -> Left ("sticker blob read failed: " <> T.pack (show e))
            Right bytes -> case mediaBlobRef sha of
              Nothing -> Left "sticker blob reference is invalid"
              Just source ->
                Right
                  ( NMedia
                      (Just source)
                      MediaMeta
                        { kind = MSticker,
                          mime = Nothing,
                          sizeBytes = Just (fromIntegral (BS.length bytes)),
                          name = Nothing,
                          description = summ,
                          raw = Just (object ["sticker_id" .= sid])
                        }
                  )

    mkObj = KM.fromList . map (first K.fromText)
    withStickerId stickerId = \case
      Object value -> Object (KM.insert "sticker_id" (toJSON stickerId) value)
      value -> value
    -- NapCat ships emoji_package_id as a JSON number; send back what
    -- parses as one, else the string we stored.
    numberish t = case TR.decimal t of
      Right (n :: Integer, "") -> Number (fromInteger n)
      _ -> String t
