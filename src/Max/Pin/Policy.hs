-- | Autonomous pin policy; explicit user commands retain their separate cap.
module Max.Pin.Policy (PinFailure (..), addToolPin, removeToolPin) where

import Data.Int (Int64)

data PinFailure = PinCallerFenced | PinNotVisible | PinAtCapacity !Int | PinNotPresent
  deriving stock (Eq, Show)

addToolPin :: Int64 -> [Int64] -> Either PinFailure [Int64]
addToolPin message pins
  | message `elem` pins = Right pins
  | length pins >= 12 = Left (PinAtCapacity (length pins))
  | otherwise = Right (pins <> [message])

removeToolPin :: Int64 -> [Int64] -> Either PinFailure [Int64]
removeToolPin message pins
  | message `elem` pins = Right (filter (/= message) pins)
  | otherwise = Left PinNotPresent
