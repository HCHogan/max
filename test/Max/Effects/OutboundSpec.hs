module Max.Effects.OutboundSpec (spec) where

import Control.Exception (bracket)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Effectful (liftIO, runEff)
import Max.DB.Message (MessageKind (KindChat))
import Max.Effects.Blob (runBlob)
import Max.Effects.Outbound
  ( OutboundDeliveryScope (..),
    OutboundRequest (..),
    SendOutcome (..),
    outboundIngestBody,
    runOutboundWith,
    sendRecorded,
    wasDelivered,
  )
import Max.IR
import Max.Platform.Types (NativeUserId (..))
import OneBot.Segment (ImageSegInfo (..), Segment (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import System.Directory (createDirectory, getTemporaryDirectory, removeFile, removePathForcibly)
import System.IO (hClose, openBinaryTempFile)
import Test.Hspec

request :: OutboundRequest
request =
  OutboundRequest
    { orKind = KindChat,
      orGroupId = GroupId 7777,
      orSelfId = UserId 1000,
      orRenderedText = Just "normalised",
      orSegments = [SegText "surface"],
      orMentionDisplays = [],
      orDeliveryScope = DeliverConversation,
      orTimeoutMs = 30000
    }

spec :: Spec
spec = describe "Outbound" $ do
  it "can be interpreted in memory without a platform or database" $ do
    seen <- newIORef Nothing
    let receipt = SentRecorded (MessageId 42)
    actual <-
      runEff
        . runOutboundWith
          (\req -> liftIO (writeIORef seen (Just req)) >> pure receipt)
        $ sendRecorded request
    actual `shouldBe` receipt
    readIORef seen `shouldReturn` Just request

  it "does not invite a duplicate retry after delivery without persistence" $ do
    wasDelivered (SendFailed "offline") `shouldBe` False
    wasDelivered (SentUnrecorded Nothing "missing message id") `shouldBe` True
    wasDelivered (SentUnrecorded (Just (MessageId 42)) "db unavailable") `shouldBe` True
    wasDelivered (SentRecorded (MessageId 42)) `shouldBe` True

  it "preserves a semantic mention and its display label for mirror lowering" $ do
    let mentioned = UserId 1578034713
        req =
          request
            { orSegments = [SegAt mentioned, SegText " 在吗，找你"],
              orMentionDisplays = [(mentioned, "用户名")]
            }
    body <- withBlobRoot $ \root -> runEff . runBlob root $ outboundIngestBody req
    body
      `shouldBe` Right (Body [NMention (NativeUserId "1578034713") "用户名", NText " 在吗，找你"])

  it "imports inline QQ image bytes before they enter canonical content" $ do
    let req = request {orSegments = [SegImage (ImageSegInfo (Just "base64://aGVsbG8=") Nothing Nothing)]}
    body <- withBlobRoot $ \root -> runEff . runBlob root $ outboundIngestBody req
    case body of
      Right (Body [NMedia (Just ref) _]) -> do
        mediaRefBlobSha ref `shouldSatisfy` maybe False ((== 64) . T.length)
        renderMediaRef ref `shouldSatisfy` (not . T.isInfixOf "base64")
      other -> expectationFailure ("unexpected canonical body: " <> show other)

withBlobRoot :: (FilePath -> IO a) -> IO a
withBlobRoot = bracket acquire removePathForcibly
  where
    acquire = do
      tmp <- getTemporaryDirectory
      (path, handle) <- openBinaryTempFile tmp "max-outbound-ingest-test"
      hClose handle
      removeFile path
      createDirectory path
      pure path
