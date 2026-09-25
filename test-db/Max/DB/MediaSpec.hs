module Max.DB.MediaSpec (spec) where

import Data.Aeson (Value (String), object, (.=))
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime, utc)
import Database.PostgreSQL.Simple (execute)
import Effectful (IOE)
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Blob (Blob)
import Helpers (insertRawMessage, truncateAll, withDb, withDbLog)
import Max.Effects.MediaQuery (MediaQuery, runMediaQuery)
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, drainInlineMedia, newToolOutputQueue, runToolOutput, runToolOutputRead)
import Max.Effects.Tools (Tool (..), toolRun)
import Max.Media.Vision (VideoAttachment (..))
import Max.ToolContext (TurnCapabilities (..), TurnIdentity (..), mkToolContext)
import Max.Tools.Images (imageToolsFor)
import Max.Tools.Video (videoToolsFor)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.Media (StoredImage (..), fetchMessageImagesInScope, fetchMessageVideoInScope)
import Max.IR (Body (..), MediaKind (MImage), MediaMeta (..), Node (NMedia, NText), mediaBlobRef)
import Max.Platform.Store.Outbound (EnqueuedOutbound (..), OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

groupA, groupB, sender, botId :: Int64
groupA = 100
groupB = 200
sender = 3001
botId = 1000

receivedAt :: UTCTime
receivedAt = UTCTime (fromGregorian 2026 8 2) (secondsToDiffTime 3600)

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "Max.DB.Media conversation isolation" $ do
    let scopeA = conversationScopeFor (GroupId groupA)

    it "does not load images attached to another conversation message" $ do
      elsewhere <- insertRawMessage pool 9002 groupB sender botId receivedAt Nothing "[image]"
      withConn pool $ \conn -> do
        _ <- execute conn "INSERT INTO images (sha256, mime_type, bytes_size, local_path) VALUES (?, 'image/png', 3, 'secret')" ["sha-image" :: String]
        _ <-
          execute
            conn
            "INSERT INTO message_images (canonical_message_id, sha256, seg_index) VALUES (?, ?, 0)"
            (elsewhere, "sha-image" :: String)
        pure ()
      rows <- withDb pool $ fetchMessageImagesInScope scopeA elsewhere Nothing
      rows `shouldSatisfy` null

    it "does not load video attached to another conversation message" $ do
      elsewhere <- insertRawMessage pool 9003 groupB sender botId receivedAt Nothing "[video]"
      withConn pool $ \conn -> do
        _ <- execute conn "INSERT INTO videos (sha256, mime_type, bytes_size, local_path, duration_seconds) VALUES (?, 'video/mp4', 3, 'secret', 2.5)" ["sha-video" :: String]
        _ <-
          execute
            conn
            "INSERT INTO message_videos (canonical_message_id, sha256, seg_index) VALUES (?, ?, 0)"
            (elsewhere, "sha-video" :: String)
        pure ()
      row <- withDb pool $ fetchMessageVideoInScope scopeA elsewhere Nothing
      row `shouldSatisfy` isNothing

    it "shows sandbox images and videos by path, naming the file" $ do
      let png = BS.pack ([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13] <> map (fromIntegral . fromEnum) "IHDR" <> [0, 0, 1, 0, 0, 0, 1, 0])
          toolContext =
            mkToolContext
              (TurnIdentity (GroupId groupA) (CanonicalMessageId 1) (UserId sender) (UserId botId) (PrincipalId 1) Nothing Nothing)
              (TurnCapabilities True False False noAdvertisedCaps False Map.empty Nothing False)
          readPath path = pure (if path == "/work/frame.png" then Right png else Left "no such file")
          clip = VideoAttachment "data:video/mp4;base64,AA==" (Just 1234) "（时长 5 秒）"
          named :: Text -> [Tool MediaTools] -> Tool MediaTools
          named name tools = case [tool | tool <- tools, tool.toolName == name] of
            tool : _ -> tool
            [] -> error ("missing tool " <> show name)
          viewImage = named "view_image" (imageToolsFor utc toolContext (curry pure) readPath)
          viewVideo = named "view_video" (videoToolsFor (\_ _ -> pure (Left "unused")) (\path _ -> pure (if path == "/chat/1-demo.mp4" then Right clip else Left "no such file")))
          call tool arguments = withDbLog pool $ do
            queue <- newToolOutputQueue 8
            result <- runToolOutput queue (runMediaQuery scopeA (toolRun tool arguments))
            media <- runToolOutputRead queue drainInlineMedia
            pure (result, media)
      (image, [shown]) <- call viewImage (object ["path" .= String "/work/frame.png"])
      image `shouldSatisfy` either (const False) (const True)
      shown.imLabel `shouldBe` "[沙箱文件 /work/frame.png]:"
      (video, [played]) <- call viewVideo (object ["path" .= String "/chat/1-demo.mp4", "start_seconds" .= (0 :: Int)])
      video `shouldSatisfy` either (const False) (const True)
      (played.imLabel, played.imVisionTokens) `shouldBe` ("[沙箱文件 /chat/1-demo.mp4]（时长 5 秒）:", Just 1234)
      (missing, _) <- call viewImage (object ["path" .= String "/work/nope.png"])
      missing `shouldBe` (Left "读不到这个沙箱文件：no such file" :: Either Text Value)

    it "indexes images Max sends so they can be viewed like received ones" $ do
      _ <- insertRawMessage pool 9004 groupA sender botId receivedAt Nothing "发张图"
      let sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
          meta = MediaMeta MImage (Just "image/jpeg") (Just 2048) (Just "sandbox.png") Nothing Nothing
      queued <-
        withDb pool $
          enqueueOutbound
            OutboundDraft
              { legacyConversationId = groupA,
                transcriptKind = "chat",
                sourceCanonicalMessageId = Nothing,
                canonicalBody = Body [NText "拼好的帧图：", NMedia (mediaBlobRef sha) meta],
                replyToCanonicalMessageId = Nothing,
                turnOutputLink = Nothing,
                monitorFireId = Nothing
              }
      let CanonicalMessageId canonical = queued.canonicalMessageId
      rows <- withDb pool $ fetchMessageImagesInScope scopeA canonical Nothing
      map (\image -> (image.storedImageSegIndex, image.storedImageMime, image.storedImageSha256)) rows
        `shouldBe` [(1, "image/jpeg", sha)]

type MediaTools = '[MediaQuery, ToolOutput, Blob, WithConnection, Log, IOE]

isNothing :: Maybe a -> Bool
isNothing Nothing = True
isNothing Just {} = False
