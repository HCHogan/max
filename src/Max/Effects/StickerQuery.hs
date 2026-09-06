{-# LANGUAGE TypeFamilies #-}

-- | Search the shared, unbanned sticker library in the exact embedding space.
module Max.Effects.StickerQuery (StickerQuery, searchStickers, runStickerQuery) where

import Data.Int (Int64)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection, query)
import Max.Embedding (EmbeddingRecord (..))

data StickerQuery :: Effect where
  SearchStickers :: EmbeddingRecord -> StickerQuery m [(Int64, Text)]

type instance DispatchOf StickerQuery = Dynamic

searchStickers :: (StickerQuery :> es) => EmbeddingRecord -> Eff es [(Int64, Text)]
searchStickers = send . SearchStickers

runStickerQuery :: (WithConnection :> es, IOE :> es) => Eff (StickerQuery : es) a -> Eff es a
runStickerQuery = interpret $ \_ -> \case
  SearchStickers record ->
    query
      "WITH compatible AS MATERIALIZED (\
      \ SELECT id,description,embedding FROM stickers WHERE NOT banned AND embedding_model=? AND embedding_dimensions=?),\
      \ ranked AS (SELECT id,description,embedding <=> ?::vector AS distance FROM compatible)\
      \ SELECT id,description FROM ranked WHERE distance<=? ORDER BY distance ASC LIMIT ?"
      (record.erModelId, record.erDimensions, record.erVector, 0.65 :: Double, 6 :: Int)
