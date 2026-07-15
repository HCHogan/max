-- |
-- @send_sticker@: let the model post a sticker from the library the
-- bot has accumulated by watching the group (see "Max.DB.Stickers" /
-- "Max.Stickers").  The model supplies a free-text mood/content
-- query; we embed it, cosine-search the captioned library, and pick
-- weighted-randomly among the closest matches — always sending the
-- single best match would make the bot post the same sticker for
-- the same mood forever.
--
-- Only registered when an embedding client is configured: without
-- vectors there is no retrieval.
module Max.Tools.Stickers
  ( stickerToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Data.ByteString.Base64 qualified as B64
import Database.PostgreSQL.Simple ((:.) (..), Only (..))
import Effectful
import Effectful.Exception (IOException, try)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, execute, query)
import Effectful.Reader.Dynamic (Reader)
import Max.DB.Message (insertOutbound)
import Max.Effects.Agent (DispatchContext (..))
import Max.Effects.NapCat (NapCat, callAction)
import Max.Effects.Tools (Tool (..))
import Max.Embedding (EmbedClient, embedTexts, renderVector)
import Max.Persistence (PersistMode, isEphemeral)
import OneBot.Action (Response (..), sendChatMsg)
import OneBot.Segment (Segment (..), stickerSeg)
import OneBot.Types (MessageId (..))
import System.FilePath ((</>))
import System.Random (randomRIO)

stickerToolsFor ::
  ( WithConnection :> es,
    NapCat :> es,
    Reader PersistMode :> es,
    Log :> es,
    IOE :> es
  ) =>
  Maybe EmbedClient ->
  FilePath -> -- blob store root
  DispatchContext ->
  [Tool es]
stickerToolsFor Nothing _ _ = []
stickerToolsFor (Just ec) blobRoot dc = [sendStickerTool ec blobRoot dc]

-- | Beyond this cosine distance the best "match" is noise; better to
-- tell the model there's nothing than to post a random sticker.
maxDist :: Double
maxDist = 0.65

-- | How many closest candidates enter the weighted draw.
topK :: Int
topK = 5

data Candidate = Candidate
  { cSha :: !Text,
    cKind :: !Text,
    cEmojiId :: !(Maybe Text),
    cPackageId :: !(Maybe Text),
    cKey :: !(Maybe Text),
    cSummary :: !(Maybe Text),
    cDescription :: !Text,
    cPath :: !Text
  }

sendStickerTool ::
  ( WithConnection :> es,
    NapCat :> es,
    Reader PersistMode :> es,
    Log :> es,
    IOE :> es
  ) =>
  EmbedClient ->
  FilePath ->
  DispatchContext ->
  Tool es
sendStickerTool ec blobRoot dc =
  Tool
    { toolName = "send_sticker",
      toolDescription =
        T.unwords
          [ "从表情包库挑一张发到当前对话。query 描述你想表达的情绪或内容",
            "（如\"嘲讽\"、\"开心的猫猫\"、\"无语\"），会按语义匹配群里出现过的表情包。",
            "偶尔用来活跃气氛或代替一句话回应；不要每条回复都发，也不要连发。",
            "返回实际发出的表情描述。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "query"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("想表达的情绪/内容，中文短语" :: Text)
                      ]
                ],
            "required" .= (["query"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "query")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (q :: Text) -> run q
    }
  where
    run q = do
      evec <- liftIO (embedTexts ec [q])
      case evec of
        Left err -> pure $ Left ("embedding failed: " <> err)
        Right [vec] -> do
          rows <-
            query
              "SELECT s.sha256, s.kind, s.emoji_id, s.emoji_package_id, s.mface_key \
              \     , s.summary, s.description, i.local_path \
              \     , (s.embedding <=> ?::vector) AS dist \
              \  FROM stickers s JOIN images i USING (sha256) \
              \  WHERE s.embedding IS NOT NULL AND NOT s.banned \
              \  ORDER BY dist ASC LIMIT ?"
              (renderVector vec, topK)
          let cands =
                [ Candidate sha kind eid pid key summ desc path
                | ((sha, kind, eid, pid, key) :. (summ, desc, path, dist)) <-
                    rows ::
                      [ (Text, Text, Maybe Text, Maybe Text, Maybe Text)
                          :. (Maybe Text, Text, Text, Double)
                      ],
                  dist <= maxDist
                ]
          mPick <- liftIO (pickWeighted cands)
          case mPick of
            Nothing -> pure $ Left "表情包库里没有贴切的（库还小或都不匹配）；就用文字吧"
            Just c -> sendIt q c
        Right _ -> pure $ Left "embedding failed: bad vector count"

    sendIt q c = do
      esegs <- buildSegs c
      case esegs of
        Left err -> pure $ Left err
        Right segs -> do
          eres <- callAction (sendChatMsg dc.dcGroupId segs) 30000
          case eres of
            Left err -> pure $ Left ("send failed: " <> err)
            Right (Response _ rc payload _)
              | rc /= 0 -> pure $ Left ("send retcode " <> T.pack (show rc))
              | otherwise -> do
                  _ <-
                    execute
                      "UPDATE stickers SET times_sent = times_sent + 1 WHERE sha256 = ?"
                      (Only c.cSha)
                  ephemeral <- isEphemeral
                  case parseEither (withObject "send_resp" (\o -> o .: "message_id")) payload of
                    Right (outMid :: Int64)
                      | not ephemeral ->
                          insertOutbound
                            dc.dcGroupId
                            dc.dcSelfId
                            "max"
                            (MessageId outMid)
                            (Just ("[表情包: " <> T.take 60 c.cDescription <> "]"))
                            segs
                    _ -> pure ()
                  logInfo "sticker sent" $
                    object ["sha" .= c.cSha, "query" .= q, "kind" .= c.cKind]
                  pure $ Right (object ["sent" .= c.cDescription])

    -- mface with full metadata resends natively (animates in-client);
    -- anything else goes out as an image flagged sub_type=1.
    buildSegs c = case (c.cKind, c.cEmojiId, c.cPackageId, c.cKey) of
      ("mface", Just eid, Just pid, Just key) ->
        pure . Right $
          [ SegOther "mface" . Object . mkObj $
              [ ("emoji_id", String eid),
                ("emoji_package_id", numberish pid),
                ("key", String key)
              ]
                <> [("summary", String s) | Just s <- [c.cSummary]]
          ]
      _ -> do
        ebytes <- try @IOException (liftIO (BS.readFile (blobRoot </> T.unpack c.cPath)))
        pure $ case ebytes of
          Left e -> Left ("sticker blob read failed: " <> T.pack (show e))
          Right bytes ->
            Right [stickerSeg ("base64://" <> TE.decodeUtf8 (B64.encode bytes))]

    mkObj = KM.fromList . map (\(k, v) -> (K.fromText k, v))
    -- NapCat ships emoji_package_id as a JSON number; send back what
    -- parses as one, else the string we stored.
    numberish t = case TR.decimal t of
      Right (n :: Integer, "") -> Number (fromInteger n)
      _ -> String t

-- | Halving weights by rank: closest match twice as likely as the
-- next, but everything in the (already distance-filtered) pool has a
-- real chance.
pickWeighted :: [a] -> IO (Maybe a)
pickWeighted [] = pure Nothing
pickWeighted xs = do
  let ws = zipWith (\i x -> ((0.5 :: Double) ^ i, x)) [(0 :: Int) ..] xs
      total = sum (map fst ws)
  r <- randomRIO (0, total)
  pure (Just (walk r ws))
  where
    walk _ [(_, x)] = x
    walk r ((w, x) : rest)
      | r <= w = x
      | otherwise = walk (r - w) rest
    walk _ [] = error "pickWeighted: unreachable (xs non-empty)"
