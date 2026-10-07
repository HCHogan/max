{-# LANGUAGE TypeFamilies #-}

-- | Destiny requests as tools see them. The interpreter binds the turn's
-- author, so requests carry no principal, token or credential: a tool can
-- only ever act as the person who asked.
module Max.Effects.Destiny
  ( Destiny,
    DestinyWrite (..),
    destinyAccount,
    destinyRead,
    destinyWrite,
    destinyLookup,
    destinySearch,
    runDestiny,
  )
where

import Data.Aeson (Value)
import Data.Int (Int64)
import Data.Text (Text)
import Effectful
  ( Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    type (:>),
  )
import Effectful.Dispatch.Dynamic (interpret, send)

-- | A write's outcome as far as Max can know it.
data DestinyWrite
  = WriteApplied !Value
  | -- | Bungie refused; nothing changed.
    WriteRefused !Text
  | -- | The request may or may not have reached the game.
    WriteUncertain !Text
  deriving stock (Show, Eq)

data Destiny :: Effect where
  DestinyAccount :: Destiny m Value
  DestinyRead :: Text -> Value -> Maybe Value -> Bool -> Destiny m (Either Text Value)
  DestinyWriteCall :: Text -> Value -> Destiny m DestinyWrite
  DestinyLookup :: Text -> [Int64] -> Destiny m (Either Text Value)
  DestinySearch :: Maybe Text -> Text -> Int -> Destiny m (Either Text Value)

type instance DispatchOf Destiny = Dynamic

destinyAccount :: (Destiny :> es) => Eff es Value
destinyAccount = send DestinyAccount

-- | Path, query object, optional body (player searches only), and whether to
-- bypass Bungie's URL-keyed response cache.
destinyRead :: (Destiny :> es) => Text -> Value -> Maybe Value -> Bool -> Eff es (Either Text Value)
destinyRead path query body fresh = send (DestinyRead path query body fresh)

destinyWrite :: (Destiny :> es) => Text -> Value -> Eff es DestinyWrite
destinyWrite path body = send (DestinyWriteCall path body)

destinyLookup :: (Destiny :> es) => Text -> [Int64] -> Eff es (Either Text Value)
destinyLookup kind hashes = send (DestinyLookup kind hashes)

destinySearch :: (Destiny :> es) => Maybe Text -> Text -> Int -> Eff es (Either Text Value)
destinySearch kind term limit = send (DestinySearch kind term limit)

runDestiny ::
  Eff es Value ->
  (Text -> Value -> Maybe Value -> Bool -> Eff es (Either Text Value)) ->
  (Text -> Value -> Eff es DestinyWrite) ->
  (Text -> [Int64] -> Eff es (Either Text Value)) ->
  (Maybe Text -> Text -> Int -> Eff es (Either Text Value)) ->
  Eff (Destiny : es) a ->
  Eff es a
runDestiny account readCall writeCall lookupCall searchCall = interpret $ \_ -> \case
  DestinyAccount -> account
  DestinyRead path query body fresh -> readCall path query body fresh
  DestinyWriteCall path body -> writeCall path body
  DestinyLookup kind hashes -> lookupCall kind hashes
  DestinySearch kind term limit -> searchCall kind term limit
