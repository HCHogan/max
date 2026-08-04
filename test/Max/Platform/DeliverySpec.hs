module Max.Platform.DeliverySpec (spec) where

import Control.Exception (bracket)
import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Effectful (runEff)
import Max.Effects.Blob (blobRefSha256, putBlob, runBlob)
import Max.Platform.Delivery
import System.Directory (createDirectory, getTemporaryDirectory, removeFile, removePathForcibly)
import System.IO (hClose, openBinaryTempFile)
import Test.Hspec

spec :: Spec
spec = describe "canonical delivery media" $ do
  it "projects v2 media nodes, preferring the caption and skipping sourceless ones" $ do
    let body =
          object
            [ "v" .= (2 :: Int),
              "nodes"
                .= [ object ["type" .= ("text" :: Text), "text" .= ("看这个" :: Text)],
                     mediaNode (Just "https://x/a.png"),
                     -- Sourceless media degrades to text at lowering; it is
                     -- never a deliverable attachment.
                     object ["type" .= ("media" :: Text), "kind" .= ("image" :: Text)]
                   ]
            ]
    deliveryMediaFromContent body
      `shouldBe` [DeliveryMedia "https://x/a.png" (Just "image/png") (Just 5) (Just "两只猫") Nothing]

  it "resolves content-addressed sources and rejects inline canonical bytes" $
    withBlobRoot $ \root -> do
      resolved <- runEff . runBlob root $ do
        ref <- putBlob "blob-payload"
        let sources =
              object
                [ "v" .= (2 :: Int),
                  "nodes"
                    .= [sizedMediaNode ("blob:" <> blobRefSha256 ref) 12]
                ]
        loadDeliveryMedia sources
      fmap (.bytes) resolved `shouldBe` [Just "blob-payload"]
      deliveryMediaFromContent
        (object ["v" .= (2 :: Int), "nodes" .= [sizedMediaNode "base64://YmFzZQ==" 6]])
        `shouldBe` []

mediaNode :: Maybe Text -> Value
mediaNode source =
  object
    ( [ "type" .= ("media" :: Text),
        "kind" .= ("image" :: Text),
        "mime" .= ("image/png" :: Text),
        "size" .= (5 :: Int),
        "name" .= ("a.png" :: Text),
        "description" .= ("两只猫" :: Text)
      ]
        <> maybe [] (\url -> ["source" .= url]) source
    )

sizedMediaNode :: Text -> Int -> Value
sizedMediaNode source size =
  object
    [ "type" .= ("media" :: Text),
      "kind" .= ("file" :: Text),
      "source" .= source,
      "mime" .= ("application/octet-stream" :: Text),
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
