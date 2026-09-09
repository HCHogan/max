-- | Operator-only review of an exact, bounded observation. No delivery or
-- worker operation is reachable from this module.
module Max.DB.Debt
  ( DebtKind (..),
    DebtScope (..),
    Disposition (..),
    DebtItem (..),
    ReviewPlan (..),
    exportDebt,
    reviewDebt,
    parseDebtKind,
    parseDebtScope,
  )
where

import Control.Monad (forM_, unless, when)
import Data.Aeson
import Data.Int (Int64)
import Data.List (nub)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import GHC.Generics (Generic)
import Text.Read (readMaybe)

data DebtKind
  = DeliveryUnknown | DeliveryPermanent | DispatchUnknown | MediaParked
  | MonitorParked | RequestFailed | SandboxUnknown | NotificationExhausted
  deriving stock (Eq, Show, Enum, Bounded)

kindText :: DebtKind -> Text
kindText = \case
  DeliveryUnknown -> "delivery_outcome_unknown"
  DeliveryPermanent -> "delivery_permanent_failure"
  DispatchUnknown -> "dispatch_outcome_unknown"
  MediaParked -> "media_parked"
  MonitorParked -> "monitor_fire_parked"
  RequestFailed -> "request_failed"
  SandboxUnknown -> "sandbox_outcome_unknown"
  NotificationExhausted -> "task_notification_exhausted"

parseDebtKind :: Text -> Maybe DebtKind
parseDebtKind value = case filter ((== value) . kindText) [minBound .. maxBound] of
  [kind] -> Just kind
  _ -> Nothing

instance ToJSON DebtKind where toJSON = toJSON . kindText
instance FromJSON DebtKind where
  parseJSON = withText "debt kind" $ maybe (fail "unknown debt kind") pure . parseDebtKind

data DebtScope = AllConversations | GlobalDebt | ConversationDebt !Int64
  deriving stock (Eq, Show)

scopeText :: DebtScope -> Text
scopeText = \case
  AllConversations -> "all"
  GlobalDebt -> "global"
  ConversationDebt conversation -> "conversation:" <> T.pack (show conversation)

parseDebtScope :: Text -> Maybe DebtScope
parseDebtScope "all" = Just AllConversations
parseDebtScope "global" = Just GlobalDebt
parseDebtScope value = do
  suffix <- T.stripPrefix "conversation:" value
  conversation <- readMaybe (T.unpack suffix)
  if conversation > 0 then Just (ConversationDebt conversation) else Nothing

instance ToJSON DebtScope where toJSON = toJSON . scopeText
instance FromJSON DebtScope where
  parseJSON = withText "debt scope" $ maybe (fail "expected all, global or conversation:<canonical id>") pure . parseDebtScope

data Disposition = Accepted | Resolved | Reopened deriving stock (Eq, Show)

dispositionText :: Disposition -> Text
dispositionText = \case Accepted -> "accepted"; Resolved -> "resolved"; Reopened -> "reopened"

instance ToJSON Disposition where toJSON = toJSON . dispositionText
instance FromJSON Disposition where
  parseJSON = withText "disposition" $ \case
    "accepted" -> pure Accepted
    "resolved" -> pure Resolved
    "reopened" -> pure Reopened
    _ -> fail "expected accepted, resolved or reopened"

data DebtItem = DebtItem
  { entityId :: !Int64,
    conversationId :: !(Maybe Int64),
    observedAt :: !UTCTime,
    fingerprint :: !Text,
    snapshot :: !Value
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON DebtItem
instance FromJSON DebtItem
instance FromRow DebtItem where
  fromRow = DebtItem <$> field <*> field <*> field <*> field <*> field

-- A freshly exported plan cannot mutate anything until review metadata is
-- supplied. The original observation stays in the plan for resolved reviews.
data ReviewPlan = ReviewPlan
  { schemaVersion :: !Int,
    kind :: !DebtKind,
    scope :: !DebtScope,
    before :: !UTCTime,
    actor :: !Text,
    disposition :: !(Maybe Disposition),
    reason :: !Text,
    evidence :: !Text,
    items :: ![DebtItem]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ReviewPlan
instance FromJSON ReviewPlan

exportDebt :: Connection -> DebtKind -> DebtScope -> UTCTime -> IO ReviewPlan
exportDebt connection kind scope cutoff = do
  let conversation = case scope of ConversationDebt value -> Just value; _ -> Nothing
  items <- query connection
    "SELECT entity_id,conversation_id,observed_at,fingerprint,snapshot FROM operational_debt \
    \WHERE kind=? AND observed_at<=? AND (?='all' OR (?='global' AND conversation_id IS NULL) OR conversation_id=?) \
    \ORDER BY entity_id LIMIT 10001"
    (kindText kind, cutoff, scopeText scope, scopeText scope, conversation)
  when (length items > 10000) $ fail "more than 10000 items; narrow the scope or cutoff"
  pure (ReviewPlan 1 kind scope cutoff "" Nothing "" "" items)

reviewDebt :: Connection -> ReviewPlan -> IO Int
reviewDebt connection plan = withTransaction connection $ do
  unless (plan.schemaVersion == 1) $ fail "unsupported review schema"
  decision <- maybe (fail "set disposition after examining the exported observations") pure plan.disposition
  when (any (T.null . T.strip) [plan.actor, plan.reason, plan.evidence]) $
    fail "actor, reason and evidence are required"
  unless (not (null plan.items) && length plan.items <= 10000) $ fail "review requires 1..10000 exact items"
  let ids = map (.entityId) plan.items
  unless (length (nub ids) == length ids) $ fail "duplicate debt identifiers"
  -- Serialize competing operator reviews; source writers remain free to run.
  -- A racing new revision cannot be hidden because health joins the exact
  -- fingerprint. All validations and audit appends commit as one transaction.
  _ <- execute_ connection "LOCK TABLE operational_debt_reviews IN EXCLUSIVE MODE"
  forM_ plan.items $ \item -> do
    let scoped = case plan.scope of
          AllConversations -> True
          GlobalDebt -> isNothing item.conversationId
          ConversationDebt value -> item.conversationId == Just value
    unless (scoped && item.observedAt <= plan.before) $ fail "item falls outside the declared scope or cutoff"
    [Only calculated] <- query connection "SELECT md5(?::jsonb::text)" (Only item.snapshot)
    unless (calculated == item.fingerprint) $ fail "snapshot fingerprint was modified"
    current <- query connection
      "SELECT entity_id,conversation_id,observed_at,fingerprint,snapshot FROM operational_debt WHERE kind=? AND entity_id=?"
      (kindText plan.kind, item.entityId)
    prior <- query connection
      "SELECT count(*) FROM operational_debt_reviews WHERE kind=? AND entity_id=? AND fingerprint=? AND snapshot=? AND conversation_id IS NOT DISTINCT FROM ?"
      (kindText plan.kind, item.entityId, item.fingerprint, item.snapshot, item.conversationId)
    case decision of
      Accepted -> unless (current == [item]) $ fail "debt changed or disappeared; export and review again"
      Resolved -> do
        -- Require an audited original observation, then independently verify
        -- the source no longer has any terminal debt of this kind/id.
        unless (prior /= [Only (0 :: Int64)] && null current) $
          fail "resolved requires a prior reviewed observation and the source debt to be cleared"
      Reopened -> unless (current == [item] || prior /= [Only (0 :: Int64)]) $ fail "no matching observation to reopen"
    _ <- execute connection
      "INSERT INTO operational_debt_reviews(kind,entity_id,conversation_id,fingerprint,snapshot,disposition,actor,reason,evidence) VALUES (?,?,?,?,?,?,?,?,?)"
      (kindText plan.kind, item.entityId, item.conversationId, item.fingerprint, item.snapshot, dispositionText decision, plan.actor, plan.reason, plan.evidence)
    pure ()
  pure (length plan.items)
