module Max.Platform.DeliverySpec (spec) where

import Control.Exception (bracket)
import Data.Aeson (Value, object, toJSON, (.=))
import Data.Text qualified as T
import Effectful (runEff)
import Max.Effects.Blob (blobRefSha256, putBlob, runBlob)
import Max.Platform.Delivery
import System.Directory (createDirectory, getTemporaryDirectory, removeFile, removePathForcibly)
import System.IO (hClose, openBinaryTempFile)
import Test.Hspec

spec :: Spec
spec = describe "canonical delivery media" $ do
  it "decodes inline hexadecimal content without IO" $ do
    deliveryMediaFromContent (content (inlineSource "68656c6c6f"))
      `shouldBe` [DeliveryMedia "inline:" (Just "text/plain") (Just 5) (Just "hello.txt") (Just "hello")]

  it "resolves content-addressed and base64 sources under the same worker boundary" $
    withBlobRoot $ \root -> do
      resolved <- runEff . runBlob root $ do
        ref <- putBlob "blob-payload"
        let sources =
              toJSON
                [ mediaPart (remoteSource ("blob:" <> blobRefSha256 ref) (Just 12)),
                  mediaPart (remoteSource "base64://YmFzZTY0LXBheWxvYWQ=" (Just 14))
                ]
        loadDeliveryMedia sources
      fmap (.bytes) resolved `shouldBe` [Just "blob-payload", Just "base64-payload"]

content :: Value -> Value
content source = toJSON [mediaPart source]

mediaPart :: Value -> Value
mediaPart source = object ["type" .= ("media" :: T.Text), "source" .= source, "caption" .= ("hello.txt" :: T.Text)]

inlineSource :: T.Text -> Value
inlineSource bytes =
  object
    [ "kind" .= ("inline" :: T.Text),
      "bytes" .= bytes,
      "mime_type" .= ("text/plain" :: T.Text)
    ]

remoteSource :: T.Text -> Maybe Int -> Value
remoteSource url size =
  object
    [ "kind" .= ("remote" :: T.Text),
      "url" .= url,
      "mime_type" .= ("application/octet-stream" :: T.Text),
      "size" .= size
    ]

withBlobRoot :: (FilePath -> IO a) -> IO a
withBlobRoot = bracket acquire removePathForcibly
  where
    acquire = do
      tmp <- getTemporaryDirectory
      (path, handle) <- openBinaryTempFile tmp "max-delivery-media-test"
      hClose handle
      removeFile path
      createDirectory path
      pure path
