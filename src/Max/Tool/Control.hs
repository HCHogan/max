-- | Trusted loop decisions emitted by host runners after accepted domain
-- operations. No JSON decoder exists: model values are never control signals.
module Max.Tool.Control (LoopControl (..), mergeControls, controlReply, mapControlText) where

import Data.Text (Text)

data LoopControl = ContinueLoop | YieldLoop !Text | FinishLoop !(Maybe Text)
  deriving stock (Eq, Show)

-- | Finish is exclusive at admission. Several successful delegations in one
-- round may yield together; preserve their host-authored receipts in order.
mergeControls :: [LoopControl] -> LoopControl
mergeControls = foldl merge ContinueLoop
  where
    merge (FinishLoop reply) _ = FinishLoop reply
    merge _ control@(FinishLoop _) = control
    merge (YieldLoop first) (YieldLoop next) = YieldLoop (first <> "\n" <> next)
    merge current ContinueLoop = current
    merge _ control = control

-- | The outer Maybe says whether the loop stops; the inner is its final text.
controlReply :: LoopControl -> Maybe (Maybe Text)
controlReply ContinueLoop = Nothing
controlReply (YieldLoop reply) = Just (Just reply)
controlReply (FinishLoop reply) = Just reply

mapControlText :: (Text -> Text) -> LoopControl -> LoopControl
mapControlText _ ContinueLoop = ContinueLoop
mapControlText f (YieldLoop reply) = YieldLoop (f reply)
mapControlText f (FinishLoop reply) = FinishLoop (f <$> reply)
