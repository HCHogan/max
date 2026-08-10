-- | One @↝λ@ as a bounded elaboration session.
--
-- ADR 002 makes elaboration a push-pull contract rather than a single shot.
-- The host pushes a bounded digest; the model pulls the evidence the digest did
-- not anticipate; then it submits one candidate segment, which is parsed and
-- validated as a whole.  Pull removes the need to /predict/ the evidence set.
-- It does not move responsibility for scope or budget, and this module is where
-- both stay with the host:
--
--   * __A pull grants no authority.__  It can only name something the host
--     already resolved into the validation environment.  A handle that is not
--     there is denied for exactly the same reason whether it is out of scope,
--     expired, or invented — from in here those are the same fact, and saying
--     which would itself leak.
--   * __Fuel is separate per dimension.__  Rounds, bytes, tokens and wall clock
--     each exhaust on their own, because a session can be cheap in one and
--     ruinous in another, and a single fused budget hides which.
--   * __The read-set is observed, not declared.__  Whatever the session
--     actually read becomes the hole's 'goalDeps', so a dependency that moves
--     before execution invalidates the candidate that was written while
--     believing it.
--
-- Everything here is pure, so a recorded session replays exactly — which is
-- what E5's offline evaluation needs and what a live-only design would not
-- give.
module Max.Plan.Session
  ( -- * Fuel
    SessionFuel (..),
    defaultSessionFuel,
    Exhaustion (..),
    exhaustionText,

    -- * Session
    Session,
    newSession,
    sessionReadSet,
    sessionRoundsUsed,
    sessionSpent,

    -- * Pulling evidence
    Pull (..),
    PullGrant (..),
    PullDenial (..),
    pull,

    -- * Submitting a candidate
    Submission (..),
    submit,

    -- * Revalidation
    Staleness (..),
    stillFresh,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Max.Plan.Parse (ParseFailure, parsePlan)
import Max.Plan.Types
import Max.Plan.Validate
  ( Rejection,
    ValidPlan,
    ValidationEnv (..),
    validatePlan,
  )

-- | Per-dimension ceilings for one session.
data SessionFuel = SessionFuel
  { -- | How many pulls may be serviced before the model must submit.
    sfRounds :: !Int,
    -- | Total bytes of pulled bodies.
    sfBytes :: !Int,
    -- | Total tokens the session may add to the elaboration prompt.
    sfTokens :: !Int,
    sfWallClockMs :: !Int
  }
  deriving stock (Show, Eq)

-- | Deliberately small.  A session that needs more than a handful of pulls is
-- usually one whose digest was wrong, and the fix for that is a better digest,
-- not a longer conversation with the store.
defaultSessionFuel :: SessionFuel
defaultSessionFuel =
  SessionFuel
    { sfRounds = 4,
      sfBytes = 64 * 1024,
      sfTokens = 8000,
      sfWallClockMs = 20000
    }

data Exhaustion
  = OutOfRounds
  | OutOfBytes
  | OutOfTokens
  | OutOfTime
  deriving stock (Show, Eq)

exhaustionText :: Exhaustion -> Text
exhaustionText = \case
  OutOfRounds -> "pull rounds"
  OutOfBytes -> "pull bytes"
  OutOfTokens -> "elaboration tokens"
  OutOfTime -> "wall clock"

-- | Accumulated session state.  Opaque: the read-set must only ever grow
-- through 'pull', or it would stop being an observation.
data Session = Session
  { seFuel :: !SessionFuel,
    seRounds :: !Int,
    seBytes :: !Int,
    seTokens :: !Int,
    seElapsedMs :: !Int,
    seReadSet :: !DependencySet
  }
  deriving stock (Show, Eq)

newSession :: SessionFuel -> Session
newSession fuel =
  Session
    { seFuel = fuel,
      seRounds = 0,
      seBytes = 0,
      seTokens = 0,
      seElapsedMs = 0,
      seReadSet = noDependencies
    }

-- | What the session actually read.  Becomes the hole's 'goalDeps'.
sessionReadSet :: Session -> DependencySet
sessionReadSet = (.seReadSet)

sessionRoundsUsed :: Session -> Int
sessionRoundsUsed = (.seRounds)

-- | Bytes, tokens and elapsed milliseconds so far, for the journal.
sessionSpent :: Session -> (Int, Int, Int)
sessionSpent session = (session.seBytes, session.seTokens, session.seElapsedMs)

-- | Something the model asked to see.  The vocabulary is closed: these are the
-- namespaces ADR 004's grammar can address, and there is no free-form query.
data Pull
  = PullResult !Text
  | PullTurnRecord !Text
  deriving stock (Show, Eq)

-- | What the host loaded for a granted pull.
data PullGrant = PullGrant
  { pgBody :: !Text,
    -- | The value's fingerprint at read time, kept so 'stillFresh' can notice
    -- it moving before execution.
    pgFingerprint :: !Text,
    pgBytes :: !Int,
    pgTokens :: !Int,
    pgElapsedMs :: !Int
  }
  deriving stock (Show, Eq)

data PullDenial
  = -- | Not in the validation environment: out of scope, released, or never a
    -- handle at all.  One reason for all three on purpose.
    NotAddressable !Text
  | Exhausted !Exhaustion
  deriving stock (Show, Eq)

-- | Service one pull.
--
-- The caller supplies the loaded body; this decides whether it may be spent and
-- records it.  Fuel is checked against the /result/ of loading rather than
-- before it, because a pull's true cost is not known until the bytes exist —
-- and a session that would go over is denied rather than truncated, so the
-- model never reasons from half a document.
pull ::
  ValidationEnv ->
  Session ->
  Pull ->
  PullGrant ->
  Either PullDenial Session
pull env session request grant = do
  key <- addressable
  spend
  pure
    session
      { seRounds = session.seRounds + 1,
        seBytes = session.seBytes + grant.pgBytes,
        seTokens = session.seTokens + grant.pgTokens,
        seElapsedMs = session.seElapsedMs + grant.pgElapsedMs,
        seReadSet = observeDependency key grant.pgFingerprint session.seReadSet
      }
  where
    fuel = session.seFuel

    addressable = case request of
      PullResult handle
        | Map.member handle env.venHandles -> Right (DepResult handle)
        | otherwise -> Left (NotAddressable handle)
      -- Turn records are addressable whenever the environment resolved one of
      -- their results, which is the same scope proof.
      PullTurnRecord handle
        | any (turnOf handle) (Map.keys env.venHandles) -> Right (DepTurnRecord handle)
        | otherwise -> Left (NotAddressable handle)

    -- @t#3@ is addressable when some resolved @t#3:r<n>@ proved that turn is in
    -- scope.
    turnOf handle resolved = (handle <> ":") `T.isPrefixOf` resolved

    spend
      | session.seRounds + 1 > fuel.sfRounds = Left (Exhausted OutOfRounds)
      | session.seBytes + grant.pgBytes > fuel.sfBytes = Left (Exhausted OutOfBytes)
      | session.seTokens + grant.pgTokens > fuel.sfTokens = Left (Exhausted OutOfTokens)
      | session.seElapsedMs + grant.pgElapsedMs > fuel.sfWallClockMs = Left (Exhausted OutOfTime)
      | otherwise = Right ()

-- | The end of a session: one candidate, admitted or not.
data Submission
  = Admitted !ValidPlan !DependencySet
  | -- | The surface did not parse.  An ordinary elaboration failure.
    Unparsed !ParseFailure
  | -- | It parsed and the kernel refused it.
    Refused !Rejection
  deriving stock (Show, Eq)

-- | Parse and validate one candidate segment, and attach what the session read.
--
-- The read-set lands on every hole the candidate leaves behind, because those
-- are the goals whose later elaboration inherits this session's assumptions.
-- The plan itself is validated first: attaching dependencies to a plan the
-- kernel would reject just decorates something that will never run.
submit :: ValidationEnv -> Text -> Session -> Text -> Submission
submit env root session source =
  case parsePlan source of
    Left failure -> Unparsed failure
    Right plan -> case validatePlan env root (withDeps plan) of
      Left rejection -> Refused rejection
      Right valid -> Admitted valid session.seReadSet
  where
    withDeps = \case
      Hole goal -> Hole goal {goalDeps = session.seReadSet}
      Call call continuation -> Call call (withDeps continuation)
      Let binder expr continuation -> Let binder expr (withDeps continuation)
      Fork fork continuation ->
        Fork
          fork {fnChildren = [(binder, goal {goalDeps = session.seReadSet}) | (binder, goal) <- fork.fnChildren]}
          (withDeps continuation)
      Guard condition consequent alternative ->
        Guard condition (withDeps consequent) (withDeps alternative)
      done@(Done _) -> done

-- | A dependency that moved between being read and being acted on.
data Staleness = Staleness
  { stKey :: !DependencyKey,
    stReadAs :: !Text,
    stNow :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

-- | Check a candidate's assumptions against the world as it is now.
--
-- Called after the session ends and before execution begins.  A value that
-- vanished counts as changed: the candidate was written believing it was there.
stillFresh ::
  -- | Current fingerprints, by key.
  Map DependencyKey Text ->
  DependencySet ->
  Either Staleness ()
stillFresh current observed =
  case [stale key was | (key, was) <- Map.toAscList observed.unDependencySet, moved key was] of
    [] -> Right ()
    first : _ -> Left first
  where
    moved key was = Map.lookup key current /= Just was
    stale key was = Staleness {stKey = key, stReadAs = was, stNow = Map.lookup key current}
