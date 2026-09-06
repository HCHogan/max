-- | Frozen monitor definition and overlap decisions. Occurrence input is
-- data; all authority comes from the arm-time ceiling and current owner.
module Max.Monitor.Policy
  ( OverlapPolicy (..),
    parseOverlapPolicy,
    overlapPolicyText,
    OccurrenceDisposition (..),
    dispositionText,
    parseOccurrenceDisposition,
    decideOverlap,
    DefinitionSnapshot (..),
    restoreSnapshot,
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Max.Task.Types (TaskProfile, parseProfile, profileName)

data OverlapPolicy = Coalesce | QueueOccurrences deriving stock (Eq, Show)

overlapPolicyText :: OverlapPolicy -> Text
overlapPolicyText Coalesce = "coalesce"
overlapPolicyText QueueOccurrences = "queue"

parseOverlapPolicy :: Text -> Maybe OverlapPolicy
parseOverlapPolicy "coalesce" = Just Coalesce
parseOverlapPolicy "queue" = Just QueueOccurrences
parseOverlapPolicy _ = Nothing

data OccurrenceDisposition = PendingOccurrence | TaskOccurrence | CoalescedOccurrence | OverflowOccurrence | CancelledOccurrence
  deriving stock (Eq, Show)

dispositionText :: OccurrenceDisposition -> Text
dispositionText = \case
  PendingOccurrence -> "pending"
  TaskOccurrence -> "task"
  CoalescedOccurrence -> "coalesced"
  OverflowOccurrence -> "overflow"
  CancelledOccurrence -> "cancelled"

parseOccurrenceDisposition :: Text -> Maybe OccurrenceDisposition
parseOccurrenceDisposition = \case
  "pending" -> Just PendingOccurrence
  "task" -> Just TaskOccurrence
  "coalesced" -> Just CoalescedOccurrence
  "overflow" -> Just OverflowOccurrence
  "cancelled" -> Just CancelledOccurrence
  _ -> Nothing

decideOverlap :: OverlapPolicy -> Int -> Int -> OccurrenceDisposition
decideOverlap Coalesce _ queued | queued > 0 = CoalescedOccurrence
decideOverlap QueueOccurrences capacity queued | queued >= capacity = OverflowOccurrence
decideOverlap _ _ _ = PendingOccurrence

data DefinitionSnapshot = DefinitionSnapshot
  { goal :: !Text,
    grants :: !(Map Text Text),
    requiredRole :: !Text,
    profile :: !TaskProfile,
    changeOnly :: !Bool,
    overlap :: !OverlapPolicy,
    capacity :: !Int,
    browserProfile :: !(Maybe Int64),
    browserVersion :: !(Maybe Int64)
  }
  deriving stock (Eq, Show)

instance ToJSON DefinitionSnapshot where
  toJSON snapshot =
    object $
      [ "goal" .= snapshot.goal,
        "grants" .= object ["tool_grants" .= snapshot.grants],
        "required_role" .= snapshot.requiredRole,
        "profile" .= profileName snapshot.profile,
        "change_only" .= snapshot.changeOnly,
        "overlap" .= overlapPolicyText snapshot.overlap,
        "queue_limit" .= snapshot.capacity
      ]
        <> ["browser_profile_id" .= identifier | Just identifier <- [snapshot.browserProfile]]
        <> ["browser_profile_version" .= version | Just version <- [snapshot.browserVersion]]

instance FromJSON DefinitionSnapshot where
  parseJSON = withObject "monitor definition snapshot" $ \fields -> do
    capability <- fields .: "profile" >>= maybe (fail "invalid monitor task profile") pure . parseProfile
    overlap <- fields .: "overlap" >>= maybe (fail "invalid monitor overlap policy") pure . parseOverlapPolicy
    ceiling <- fields .: "grants" >>= withObject "effect ceiling" (\stored -> stored .:? "tool_grants" .!= mempty)
    DefinitionSnapshot
      <$> fields .: "goal"
      <*> pure ceiling
      <*> fields .: "required_role"
      <*> pure capability
      <*> fields .: "change_only"
      <*> pure overlap
      <*> fields .: "queue_limit"
      <*> fields .:? "browser_profile_id"
      <*> fields .:? "browser_profile_version"

-- | Pre-ADR008 occurrences can lack fields introduced by later migrations.
-- Only absent fields inherit the same definition fallback used by the old
-- reader; present malformed data fails closed instead of granting authority.
restoreSnapshot :: DefinitionSnapshot -> Value -> Maybe DefinitionSnapshot
restoreSnapshot fallback (Object fields) = case toJSON fallback of
  Object defaults -> case fromJSON (Object (KeyMap.union fields defaults)) of
    Success snapshot -> Just snapshot
    Error _ -> Nothing
  _ -> Nothing
restoreSnapshot _ _ = Nothing
