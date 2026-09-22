-- | Typed decoding for text and native JSON columns at the SQL boundary.
-- Malformed durable values are conversion failures, never default authority.
module Max.DB.Codec (jsonField, jsonbField, nullableJsonbField, enumField, queryRows, databaseNow, jsonText, Jsonb (..), exactlyOne) where

import Data.Aeson
  ( FromJSON,
    Result (..),
    ToJSON,
    Value,
    eitherDecodeStrict',
    encode,
    fromJSON,
  )
import Data.ByteString.Lazy qualified as LBS (toStrict)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
  ( decodeUtf8,
    encodeUtf8,
  )
import Data.Time (UTCTime)
import Data.Typeable (Typeable)
import Database.PostgreSQL.Simple qualified as SQL (queryWith)
import Database.PostgreSQL.Simple.FromField
  ( ResultError (ConversionFailed),
    fromField,
    returnError,
  )
import Database.PostgreSQL.Simple.FromRow (RowParser, fieldWith)
import Database.PostgreSQL.Simple.ToField
  ( ToField (..),
    toJSONField,
  )
import Database.PostgreSQL.Simple.ToRow (ToRow)
import Database.PostgreSQL.Simple.Types (Only (..), Query)
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.PostgreSQL
  ( WithConnection,
    query,
    withConnection,
  )

jsonField :: (FromJSON a, Typeable a) => RowParser a
jsonField = fieldWith $ \column bytes -> do
  encoded <- fromField column bytes
  either (returnError ConversionFailed column) pure (eitherDecodeStrict' (TE.encodeUtf8 encoded))

enumField :: (Typeable a) => (Text -> Maybe a) -> RowParser a
enumField parse = fieldWith $ \column bytes -> do
  value <- fromField column bytes
  maybe (returnError ConversionFailed column "unknown domain value") pure (parse value)

-- | Explicit row parsers keep SQL instances out of domain presentation types.
queryRows :: (WithConnection :> es, IOE :> es, ToRow parameters) => RowParser a -> Query -> parameters -> Eff es [a]
queryRows parser sql parameters = withConnection $ \connection -> liftIO (SQL.queryWith parser connection sql parameters)

-- | Native JSON/JSONB columns, including nullable outer-join columns. Keep
-- decoding inside RowParser so malformed durable data reports ConversionFailed.
jsonbField :: (FromJSON a, Typeable a) => RowParser a
jsonbField = fieldWith $ \column bytes -> do
  value <- fromField column bytes
  case fromJSON value of
    Error message -> returnError ConversionFailed column message
    Success decoded -> pure decoded

nullableJsonbField :: (FromJSON a, Typeable a) => RowParser (Maybe a)
nullableJsonbField = fieldWith $ \column bytes -> case bytes of
  Nothing -> pure Nothing
  Just _ -> do
    value <- fromField column bytes
    case fromJSON value of
      Error message -> returnError ConversionFailed column message
      Success decoded -> pure (Just decoded)

databaseNow :: (WithConnection :> es, IOE :> es) => Eff es UTCTime
databaseNow = do
  rows <- query "SELECT clock_timestamp()" ()
  case rows of [Only now] -> pure now; _ -> error "database clock missing"

jsonText :: (ToJSON a) => a -> Text
jsonText = TE.decodeUtf8 . LBS.toStrict . encode

newtype Jsonb = Jsonb Value

instance ToField Jsonb where
  toField (Jsonb value) = toJSONField value

exactlyOne :: String -> [Only a] -> a
exactlyOne _ [Only value] = value
exactlyOne label _ = error (label <> ": expected exactly one row")
