module Max.Text (tshow, encodeText, readIntegral) where

import Data.Aeson (ToJSON, encode)
import Data.ByteString.Lazy qualified as LBS (toStrict)
import Data.Text (Text)
import Data.Text qualified as T (pack)
import Data.Text.Encoding qualified as TE (decodeUtf8)
import Data.Text.Read qualified as TR (decimal, signed)

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | JSON into 'Text', for the columns and payloads that store rendered JSON
-- rather than a @jsonb@ value.
encodeText :: (ToJSON a) => a -> Text
encodeText = TE.decodeUtf8 . LBS.toStrict . encode

-- | Parse a whole 'Text' as one signed integer, or nothing.  Deliberately
-- stricter than @reads@ on a 'String': no surrounding whitespace, no
-- parenthesised negatives, no trailing junk — every caller is reading an id
-- it wrote itself, and a partial parse there is a defect, not a value.
readIntegral :: (Integral a) => Text -> Maybe a
readIntegral raw = case TR.signed TR.decimal raw of
  Right (value, "") -> Just value
  _ -> Nothing
