-- | Typed decoding at the SQL boundary. JSON columns are selected as text;
-- malformed durable values are conversion failures, never default authority.
module Max.DB.Codec (jsonField, enumField, integralField, queryRows) where

import Data.Aeson (FromJSON, eitherDecodeStrict')
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Typeable (Typeable)
import Database.PostgreSQL.Simple qualified as SQL
import Database.PostgreSQL.Simple.FromField (ResultError (ConversionFailed), fromField, returnError)
import Database.PostgreSQL.Simple.FromRow (RowParser, fieldWith)
import Database.PostgreSQL.Simple.ToRow (ToRow)
import Database.PostgreSQL.Simple.Types (Query)
import Effectful
import Effectful.PostgreSQL (WithConnection, withConnection)

jsonField :: (FromJSON a, Typeable a) => RowParser a
jsonField = fieldWith $ \column bytes -> do
  encoded <- fromField column bytes
  either (returnError ConversionFailed column) pure (eitherDecodeStrict' (TE.encodeUtf8 encoded))

enumField :: (Typeable a) => (Text -> Maybe a) -> RowParser a
enumField parse = fieldWith $ \column bytes -> do
  value <- fromField column bytes
  maybe (returnError ConversionFailed column "unknown domain value") pure (parse value)

-- | PostgreSQL SUM(bigint) returns arbitrary-precision numeric. Preserve its
-- integral range instead of coercing it to machine Int or a floating value.
integralField :: RowParser Integer
integralField = fieldWith $ \column bytes -> do
  value <- fromField column bytes
  case floatingOrInteger (value :: Scientific) of
    Right integer -> pure integer
    Left (_ :: Double) -> returnError ConversionFailed column "expected integral numeric"

-- | Explicit row parsers keep SQL instances out of domain presentation types.
queryRows :: (WithConnection :> es, IOE :> es, ToRow parameters) => RowParser a -> Query -> parameters -> Eff es [a]
queryRows parser sql parameters = withConnection $ \connection -> liftIO (SQL.queryWith parser connection sql parameters)
