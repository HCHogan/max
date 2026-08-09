-- | Pure policy for ADR 005's verbatim replay tier.
--
-- The digest tier is the floor and is always correct; replay is a cache on
-- top of it.  Everything here therefore answers one question — may these
-- archived wire bytes be resent, and how far back — and answers it
-- conservatively: any doubt degrades to digest rather than risking a
-- provider rejection or a resurrected stale environment.
--
-- Two invariants shape the module:
--
--   * __An archive is never truth.__  Rejecting one costs a cheaper prompt,
--     never correctness, so every check fails closed.
--   * __Admission is a contiguous suffix.__  A chain is replayed newest-first
--     and stops at the first candidate that fails any check, because a hole
--     in the middle of a reasoning chain is worse than a shorter chain.
module Max.Turn.Replay
  ( ReplayCandidate (..),
    TurnArchive (..),
    ReplayEnvironment (..),
    ReplayReject (..),
    ReplaySegment (..),
    ReplayPlan (..),
    replayRejectText,
    candidateRejection,
    planReplay,
    planReplayMessages,
    planCoveredCanonicalIds,
    defaultChainTokenBudget,
    defaultChainDepth,
    providerValidityDays,
  )
where

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Int (Int64)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime)
import Max.Context (estimateMessagesTokens)
import Max.Effects.LLM (ChatMessage (..))
import Max.Turn.Types (AgentTurnRef (..))

-- | One turn on the fork-from chain, with the durable facts the predicate
-- needs.  Loaded by "Max.DB.TurnContinuity"; never model-supplied.
data ReplayCandidate = ReplayCandidate
  { rcTurn :: !AgentTurnRef,
    rcProfile :: !(Maybe Text),
    rcPromptMajor :: !Int,
    rcCatalogFingerprint :: !(Maybe Text),
    rcArchiveSha :: !(Maybe Text),
    rcArchiveCreatedAt :: !(Maybe UTCTime),
    rcArchiveExpiresAt :: !(Maybe UTCTime),
    -- | The turn's own trigger, already rendered as one host-authored
    -- transcript line.  Replay needs it because the archive holds only what
    -- the turn /appended/ after that trigger.
    rcTriggerCanonicalId :: !(Maybe Int64),
    rcTriggerLine :: !(Maybe Text),
    -- | Visible outputs this turn produced, for ledger dedup.
    rcOutputCanonicalIds :: ![Int64]
  }
  deriving stock (Show, Eq)

-- | The decoded archive blob.  Only 'taAppended' is replayed; the rest is
-- carried for provenance assertions and debugging.
data TurnArchive = TurnArchive
  { taVersion :: !Int,
    taTurnId :: !Int64,
    taProfile :: !(Maybe Text),
    taAppended :: ![ChatMessage]
  }
  deriving stock (Show)

instance FromJSON TurnArchive where
  parseJSON = withObject "TurnArchive" $ \o ->
    TurnArchive
      <$> o .: "version"
      <*> o .: "turn_id"
      <*> o .:? "profile"
      <*> o .: "appended"

-- | Current-world facts a candidate is checked against.
data ReplayEnvironment = ReplayEnvironment
  { reNow :: !UTCTime,
    reProfile :: !Text,
    rePromptMajor :: !Int,
    reCatalogFingerprint :: !Text,
    reChainTokenBudget :: !Int
  }
  deriving stock (Show, Eq)

data ReplayReject
  = -- | Never captured, or already pruned by TTL/LRU.
    RejectNoArchive
  | -- | Retention window elapsed since capture.
    RejectArchiveExpired
  | -- | Older than any provider will still accept encrypted reasoning for.
    RejectProviderWindow
  | -- | Opaque blobs are foreign bytes to another model.
    RejectProfileChanged
  | -- | Host prompt contract moved; archived turns assumed the old one.
    RejectPromptMajorChanged
  | -- | Archived tool calls no longer match live schemas.
    RejectCatalogChanged
  | -- | Chain token budget spent; older segments fall to digest.
    RejectChainBudget
  | -- | Archive bytes unreadable or not decodable as this version.
    RejectArchiveUnreadable
  | -- | The turn's own trigger row no longer renders, so the segment would
    -- open on an assistant message answering nothing.
    RejectTriggerUnrenderable
  deriving stock (Show, Eq)

replayRejectText :: ReplayReject -> Text
replayRejectText = \case
  RejectNoArchive -> "no-archive"
  RejectArchiveExpired -> "archive-expired"
  RejectProviderWindow -> "provider-validity-window"
  RejectProfileChanged -> "profile-changed"
  RejectPromptMajorChanged -> "prompt-major-changed"
  RejectCatalogChanged -> "tool-catalog-changed"
  RejectChainBudget -> "chain-budget"
  RejectArchiveUnreadable -> "archive-unreadable"
  RejectTriggerUnrenderable -> "trigger-unrenderable"

-- | One admitted turn's verbatim contribution.
data ReplaySegment = ReplaySegment
  { rsTurn :: !AgentTurnRef,
    rsMessages :: ![ChatMessage],
    rsEstimatedTokens :: !Int,
    rsCoveredCanonicalIds :: ![Int64]
  }
  deriving stock (Show)

data ReplayPlan = ReplayPlan
  { -- | Oldest first, ready to splice after the system prompt.
    rpSegments :: ![ReplaySegment],
    -- | Why the chain stopped where it did.  Present even on a full-depth
    -- success ('Nothing' only when the walk consumed every candidate).
    rpStoppedBecause :: !(Maybe ReplayReject),
    rpEstimatedTokens :: !Int
  }
  deriving stock (Show)

-- | Chain token budget for the verbatim suffix.  Deliberately a fraction of
-- any real context window: replay competes with the live conversation, and
-- ADR 005 prefers recent work at full fidelity over long work at any.
defaultChainTokenBudget :: Int
defaultChainTokenBudget = 24000

-- | How far back the fork-from walk goes before the rest is digest by
-- construction.  A budget fuse, not a semantic limit.
defaultChainDepth :: Int
defaultChainDepth = 8

-- | Conservative floor under provider-side validity for encrypted or signed
-- reasoning.  Shorter than the archive TTL on purpose: an archive may outlive
-- the provider's willingness to accept its blobs, and a rejected request is
-- worse than a digest.
providerValidityDays :: Int
providerValidityDays = 7

-- | Every non-budget check, in order of how cheaply it settles the question.
-- 'Nothing' means the candidate may be admitted if the budget allows.
candidateRejection :: ReplayEnvironment -> ReplayCandidate -> Maybe ReplayReject
candidateRejection env candidate
  | Nothing <- candidate.rcArchiveSha = Just RejectNoArchive
  | maybe True (<= env.reNow) candidate.rcArchiveExpiresAt = Just RejectArchiveExpired
  | maybe True beyondProviderWindow candidate.rcArchiveCreatedAt = Just RejectProviderWindow
  | candidate.rcProfile /= Just env.reProfile = Just RejectProfileChanged
  | candidate.rcPromptMajor /= env.rePromptMajor = Just RejectPromptMajorChanged
  | candidate.rcCatalogFingerprint /= Just env.reCatalogFingerprint = Just RejectCatalogChanged
  | Nothing <- candidate.rcTriggerLine = Just RejectTriggerUnrenderable
  | otherwise = Nothing
  where
    beyondProviderWindow created =
      addUTCTime (fromIntegral providerValidityDays * 86400) created <= env.reNow

-- | Admit a contiguous verbatim suffix.
--
-- Candidates arrive newest-first (the continuation target, then its
-- ancestors).  The walk stops at the first rejection, so the result is always
-- a suffix of the chain and never interleaves digest and verbatim.  The
-- returned segments are reversed to oldest-first, which is the order they are
-- spliced into the request.
--
-- The caller supplies each candidate's decoded archive — the items that turn
-- /appended/ — and this function completes the segment by opening it with the
-- turn's own trigger, because an archive alone would start on an assistant
-- message answering nothing.  A candidate whose archive failed to load is
-- passed in as 'Left', which stops the walk exactly like any other rejection.
planReplay ::
  ReplayEnvironment ->
  [(ReplayCandidate, Either ReplayReject [ChatMessage])] ->
  ReplayPlan
planReplay env = go [] 0
  where
    go admitted spent = \case
      [] -> plan admitted spent Nothing
      (candidate, loaded) : rest -> case candidateRejection env candidate of
        Just reject -> plan admitted spent (Just reject)
        Nothing -> case loaded of
          Left reject -> plan admitted spent (Just reject)
          Right appended ->
            let next = segment candidate appended
             in if spent + next.rsEstimatedTokens > env.reChainTokenBudget
                  then plan admitted spent (Just RejectChainBudget)
                  else go (next : admitted) (spent + next.rsEstimatedTokens) rest

    segment candidate appended =
      let messages = foldr ((:) . MsgUser) appended candidate.rcTriggerLine
       in ReplaySegment
            { rsTurn = candidate.rcTurn,
              rsMessages = messages,
              rsEstimatedTokens = estimateMessagesTokens messages,
              rsCoveredCanonicalIds =
                maybe id (:) candidate.rcTriggerCanonicalId candidate.rcOutputCanonicalIds
            }

    -- 'admitted' accumulated newest-first, so it is already oldest-first
    -- once consed in reverse walk order.
    plan admitted spent stopped =
      ReplayPlan
        { rpSegments = admitted,
          rpStoppedBecause = stopped,
          rpEstimatedTokens = spent
        }

planReplayMessages :: ReplayPlan -> [ChatMessage]
planReplayMessages plan = concatMap (.rsMessages) plan.rpSegments

-- | Ledger rows a replayed segment already shows verbatim.  The ordinary
-- conversation window stubs these out so one utterance is never presented to
-- the model twice in two different registers.
planCoveredCanonicalIds :: ReplayPlan -> Set Int64
planCoveredCanonicalIds plan =
  Set.fromList (concatMap (.rsCoveredCanonicalIds) plan.rpSegments)
