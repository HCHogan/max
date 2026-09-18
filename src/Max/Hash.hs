-- | Stable hashes for JSON diagnostics and stored request identities.
module Max.Hash (jsonHash) where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value, encode)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

jsonHash :: Value -> Text
jsonHash = TE.decodeUtf8 . B16.encode . SHA256.hash . LBS.toStrict . encode
