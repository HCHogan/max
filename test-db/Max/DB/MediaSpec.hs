module Max.DB.MediaSpec (spec) where

import Data.Int (Int64)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Database.PostgreSQL.Simple (execute)
import Helpers (insertRawMessage, truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.Media (fetchMessageImagesInScope, fetchMessageVideoInScope)
import OneBot.Types (GroupId (..))
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
      insertRawMessage pool 9002 groupB sender botId receivedAt Nothing "[image]"
      withConn pool $ \conn -> do
        _ <- execute conn "INSERT INTO images (sha256, mime_type, bytes_size, local_path) VALUES (?, 'image/png', 3, 'secret')" ["sha-image" :: String]
        _ <- execute conn "INSERT INTO message_images (message_id, sha256, seg_index) VALUES (9002, ?, 0)" ["sha-image" :: String]
        pure ()
      rows <- withDb pool $ fetchMessageImagesInScope scopeA 9002
      rows `shouldSatisfy` null

    it "does not load video attached to another conversation message" $ do
      insertRawMessage pool 9003 groupB sender botId receivedAt Nothing "[video]"
      withConn pool $ \conn -> do
        _ <- execute conn "INSERT INTO videos (sha256, mime_type, bytes_size, local_path, duration_seconds) VALUES (?, 'video/mp4', 3, 'secret', 2.5)" ["sha-video" :: String]
        _ <- execute conn "INSERT INTO message_videos (message_id, sha256, seg_index) VALUES (9003, ?, 0)" ["sha-video" :: String]
        pure ()
      row <- withDb pool $ fetchMessageVideoInScope scopeA 9003
      row `shouldSatisfy` isNothing

isNothing :: Maybe a -> Bool
isNothing Nothing = True
isNothing Just {} = False
