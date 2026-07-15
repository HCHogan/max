-- |
-- Sticker tools for the agent, over the library the bot accumulates by
-- watching the group (see "Max.DB.Stickers" / "Max.Stickers").  Sending
-- is a deliberate two-step so the model commits to a specific sticker:
--
--   * @find_stickers@ — the model gives a free-text mood/content query;
--     we embed it, cosine-search the captioned library, and return the
--     closest matches as a numbered list of @{id, desc}@.  Nothing is
--     sent.
--   * @send_sticker@ — the model passes back one integer @id@ from that
--     list (or one it saw elsewhere) and we post that exact sticker.
--
-- The split exists because the old single free-text tool auto-sent on a
-- semantic guess, and the model — seeing its past sends rendered as
-- @[表情包: …]@ text in history — learned to just *type* the caption
-- instead of calling a tool.  An explicit integer handle makes sending
-- unambiguous.
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
stickerToolsFor (Just ec) blobRoot dc =
  [findStickersTool ec, sendStickerTool blobRoot dc]

-- | Beyond this cosine distance the best "match" is noise; better to
-- tell the model there's nothing than to surface a random sticker.
maxDist :: Double
maxDist = 0.65

-- | How many closest candidates to show the model.
topK :: Int
topK = 6

data Candidate = Candidate
  { cId :: !Int64,
    cDescription :: !Text
  }

-- | @find_stickers@: semantic search over the captioned library.
-- Returns a numbered list; sends nothing.
findStickersTool ::
  ( WithConnection :> es,
    Log :> es,
    IOE :> es
  ) =>
  EmbedClient ->
  Tool es
findStickersTool ec =
  Tool
    { toolName = "find_stickers",
      toolDescription =
        T.unwords
          [ "在表情包库里按语义搜表情，用来挑一张发。query 描述你想表达的情绪或内容",
            "（如\"嘲讽\"、\"开心的猫猫\"、\"无语\"）。返回若干候选，每个带一个整数 id 和简介。",
            "看完候选后，用 send_sticker 传其中一个 id 才会真的发出去。",
            "本工具只搜不发。"
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
              "SELECT s.id, s.description \
              \  FROM stickers s \
              \  WHERE s.embedding IS NOT NULL AND NOT s.banned \
              \    AND (s.embedding <=> ?::vector) <= ? \
              \  ORDER BY (s.embedding <=> ?::vector) ASC LIMIT ?"
              (renderVector vec, maxDist, renderVector vec, topK)
          let cands = [Candidate i d | (i, d) <- rows :: [(Int64, Text)]]
          logInfo "find_stickers" $ object ["query" .= q, "n" .= length cands]
          pure . Right $
            object
              [ "candidates"
                  .= [ object ["id" .= c.cId, "desc" .= c.cDescription]
                     | c <- cands
                     ],
                "hint"
                  .= if null cands
                    then ("库里没有贴切的，就用文字吧" :: Text)
                    else "用 send_sticker 传其中一个 id 发出去"
              ]
        Right _ -> pure $ Left "embedding failed: bad vector count"

-- | @send_sticker@: post the sticker with the given integer id.
sendStickerTool ::
  ( WithConnection :> es,
    NapCat :> es,
    Reader PersistMode :> es,
    Log :> es,
    IOE :> es
  ) =>
  FilePath ->
  DispatchContext ->
  Tool es
sendStickerTool blobRoot dc =
  Tool
    { toolName = "send_sticker",
      toolDescription =
        T.unwords
          [ "发一张表情包到当前对话。id 是整数，来自 find_stickers 的候选列表。",
            "偶尔用来活跃气氛或代替一句话回应；不要每条回复都发，也不要连发。",
            "注意：发表情只能靠这个工具；绝对不要在你的回复文字里输出",
            "\"[表情包: …]\" 这类文本——那只是历史里表情的显示样式，不是发送方式。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("要发的表情 id（来自 find_stickers）" :: Text)
                      ]
                ],
            "required" .= (["id"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "id")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (sid :: Int64) -> run sid
    }
  where
    run sid = do
      rows <-
        query
          "SELECT s.sha256, s.kind, s.emoji_id, s.emoji_package_id, s.mface_key \
          \     , s.summary, s.description, i.local_path \
          \  FROM stickers s JOIN images i USING (sha256) \
          \  WHERE s.id = ? AND NOT s.banned \
          \  LIMIT 1"
          (Only sid)
      case rows ::
             [ (Text, Text, Maybe Text, Maybe Text, Maybe Text)
                 :. (Maybe Text, Text, Text)
             ] of
        [] -> pure $ Left ("没有 id=" <> T.pack (show sid) <> " 的表情（用 find_stickers 拿有效 id）")
        (((sha, kind, eid, pid, key) :. (summ, desc, path)) : _) ->
          sendIt (Row sha kind eid pid key summ desc path)

    sendIt r = do
      esegs <- buildSegs r
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
                      (Only r.rSha)
                  ephemeral <- isEphemeral
                  case parseEither (withObject "send_resp" (\o -> o .: "message_id")) payload of
                    Right (outMid :: Int64)
                      | not ephemeral ->
                          insertOutbound
                            dc.dcGroupId
                            dc.dcSelfId
                            "max"
                            (MessageId outMid)
                            (Just ("[表情包: " <> T.take 60 r.rDescription <> "]"))
                            segs
                    _ -> pure ()
                  logInfo "sticker sent" $
                    object ["sha" .= r.rSha, "kind" .= r.rKind]
                  pure $ Right (object ["sent" .= r.rDescription])

    -- mface with full metadata resends natively (animates in-client);
    -- anything else goes out as an image flagged sub_type=1.
    buildSegs r = case (r.rKind, r.rEmojiId, r.rPackageId, r.rKey) of
      ("mface", Just eid, Just pid, Just key) ->
        pure . Right $
          [ SegOther "mface" . Object . mkObj $
              [ ("emoji_id", String eid),
                ("emoji_package_id", numberish pid),
                ("key", String key)
              ]
                <> [("summary", String s) | Just s <- [r.rSummary]]
          ]
      _ -> do
        ebytes <- try @IOException (liftIO (BS.readFile (blobRoot </> T.unpack r.rPath)))
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

-- | The fields we need to render one sticker into segments.
data Row = Row
  { rSha :: !Text,
    rKind :: !Text,
    rEmojiId :: !(Maybe Text),
    rPackageId :: !(Maybe Text),
    rKey :: !(Maybe Text),
    rSummary :: !(Maybe Text),
    rDescription :: !Text,
    rPath :: !Text
  }
