-- | Process-owned background jobs. STM owns state, budgets and joins; each job
-- has its own worker, so a parent waiting for children holds no worker slot.
module Max.Jobs
  ( Jobs,
    JobRun (..),
    JobSpec (..),
    JobView (..),
    JobResult (..),
    JobWork (..),
    JobWait (..),
    newJobs,
    admitJob,
    takeJobWork,
    attachJobTurn,
    detachJobTurn,
    completeJob,
    awaitJob,
    recordJobUsage,
    reportJobProgress,
    readJobInbox,
    jobHasFeedback,
    waitForChildren,
    listJobs,
    lookupJob,
    jobForTurn,
    authorizeJobStep,
    decideJobStep,
    steerJob,
    cancelJob,
    replaceJob,
    noticeIsCurrent,
    bindJobNotice,
    detachJobNotice,
    releaseJobNotice,
    authorizeJobPublication,
    recordJobPublication,
    taskForReply,
    allJobs,
    closeJobs,
    setJobBrowserAccess,
  )
where

import Control.Concurrent.STM
import Control.Exception (mask, onException)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (find, toList)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing, mapMaybe)
import Data.Ord (Down (..))
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Max.Execution.Types (Admission (..), ExecutionStep (..), StepReservation (..))
import Max.LLM.Types (TokenUsage)
import Max.Platform.Types (CanonicalMessageId, PrincipalId)
import Max.Task.Policy (treeModelRounds, treeToolCalls)
import Max.Task.State (TaskStatus (..), taskIsLive)
import Max.Task.Types
import Max.Tasks (TaskCancelled (..), TaskRegistry, cancelAgentTurnTask, turnIsLive)
import Max.Turn.Types (AgentTurnId, AgentTurnRef (..))
import OneBot.Types (GroupId)

data JobWork = LaunchJob !JobView | PublishJobNotice !JobView !Int !Text | RecordMonitorResult !JobView
  deriving stock (Eq, Show)

data Entry = Entry
  { view :: !JobView,
    root :: !JobRun,
    runtime :: !(Maybe (JobRun, AgentTurnRef)),
    children :: !(Set JobRun),
    childUpdates :: !(Set JobRun),
    inbox :: !(Seq Value),
    noticeVersion :: !Int,
    pendingNotice :: !(Maybe Text),
    pendingMonitor :: !Bool,
    noticeInFlight :: !Bool,
    budgetExhausted :: !Bool,
    -- | The foreground turn waiting for this awaited root's report.
    awaiter :: !(Maybe AgentTurnId)
  }

data Jobs = Jobs
  { entries :: !(TVar (Map Int64 Entry)),
    notices :: !(TVar (Map AgentTurnId (JobRun, Int))),
    publications :: !(TVar (Map CanonicalMessageId JobRun)),
    closed :: !(TVar Bool),
    tasks :: !TaskRegistry
  }

newJobs :: TaskRegistry -> IO Jobs
newJobs tasks = Jobs <$> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO False <*> pure tasks

-- | IDs come from the retained task identity sequence, never from model input.
-- Terminal entries can be discarded only after their live parent releases them.
admitJob :: Jobs -> Maybe AgentTurnId -> Int64 -> JobSpec -> IO (Either Text JobView)
admitJob jobs caller identifier requested = do
  now <- getCurrentTime
  atomically $ do
    closing <- readTVar jobs.closed
    allowed <- maybe (pure True) (turnIsLive jobs.tasks) caller
    current <- readTVar jobs.entries
    let retained job = taskIsLive job.view.status || isJust job.runtime || job.pendingMonitor || job.noticeInFlight || isJust job.pendingNotice || isJust job.awaiter || maybe False (liveRun current) job.view.spec.parent
        completed = sortOn (Down . (.view.created)) (filter (not . retained) (Map.elems current))
        kept = Map.filter retained current <> Map.fromList [(entry.view.run.jobId, entry) | entry <- take 256 completed]
        parents = ancestors kept requested.parent
        withinScope parent = parent.view.spec.group == requested.group && parent.view.spec.principal == requested.principal && Map.isSubmapOfBy (==) requested.grants parent.view.spec.grants
        deadline = minimum (addUTCTime 21600 now : requested.deadline : map (.view.spec.deadline) parents)
        spec = requested {deadline, objective = T.strip requested.objective, delegated = requested.delegated || any (.view.spec.delegated) parents}
        run = JobRun identifier 1
        root = maybe run (.root) (lookupRun kept =<< spec.parent)
        view = JobView run spec Queued Nothing Nothing 0 0 now True emptyJobUsage Nothing
        awaiter = if spec.awaited && isNothing spec.parent then caller else Nothing
        newEntry = Entry view root Nothing Set.empty Set.empty Seq.empty 0 Nothing False False False awaiter
        invalid detail = pure (Left detail)
    if closing || not allowed || Map.member identifier current
      then invalid "job caller ended or identity already exists"
      else
        if identifier <= 0 || T.null spec.objective || T.length spec.objective > 40000 || LBS.length (encode spec.inputs) > 262144
          then invalid "invalid job identity, objective, or inputs"
          else
            if deadline <= now
              then invalid "job deadline has passed"
              else
                if spec.grants /= taskGrants spec.profile spec.grants
                  then invalid "job profile cannot grant these tools"
                  else
                    if maybe False (not . liveRun kept) spec.parent || not (all withinScope parents)
                      then invalid "parent ended or child authority exceeds its parent"
                      else
                        if length parents >= 16
                          then invalid "job nesting limit"
                          else
                            if Map.size kept >= 1024 || length [() | entry <- Map.elems kept, entry.view.spec.group == spec.group, taskIsLive entry.view.status] >= 160
                              then invalid "job queue is full"
                              else do
                                let addChild parent = parent {children = Set.insert run parent.children}
                                    withParent = maybe kept (\owner -> Map.adjust addChild owner.jobId kept) spec.parent
                                writeTVar jobs.entries (Map.insert identifier newEntry withParent)
                                pure (Right view)

-- | Work queues are flags on bounded entries, so repeated progress/replacement
-- cannot accumulate an unbounded queue of obsolete events.
takeJobWork :: Jobs -> IO JobWork
takeJobWork jobs = atomically $ do
  readTVar jobs.closed >>= check . not
  entries <- readTVar jobs.entries
  case find (.pendingMonitor) (Map.elems entries) of
    Just entry -> do
      writeTVar jobs.entries (Map.insert entry.view.run.jobId (entry {pendingMonitor = False, noticeInFlight = True}) entries)
      pure (RecordMonitorResult entry.view)
    Nothing -> takeReady entries
  where
    takeReady entries = case find (\entry -> entry.view.status == Queued && isNothing entry.runtime && monitorAvailable entries entry) (Map.elems entries) of
      Just entry -> do
        let running = entry {view = entry.view {status = Running}}
        writeTVar jobs.entries (Map.insert entry.view.run.jobId running entries)
        pure (LaunchJob running.view)
      Nothing -> case find (\entry -> not entry.noticeInFlight && isJust entry.pendingNotice) (Map.elems entries) of
        Just entry | Just body <- entry.pendingNotice -> do
          writeTVar jobs.entries (Map.insert entry.view.run.jobId (entry {pendingNotice = Nothing, noticeInFlight = True}) entries)
          pure (PublishJobNotice entry.view entry.noticeVersion body)
        _ -> retry

attachJobTurn :: Jobs -> JobRun -> AgentTurnRef -> IO Bool
attachJobTurn jobs run turn = atomically $ do
  entries <- readTVar jobs.entries
  case lookupRun entries run of
    Just entry | entry.view.status == Running && isNothing entry.runtime -> do
      writeTVar jobs.entries (Map.insert run.jobId (entry {runtime = Just (run, turn)}) entries)
      pure True
    _ -> pure False

detachJobTurn :: Jobs -> JobRun -> IO ()
detachJobTurn jobs run =
  atomically $
    modifyTVar' jobs.entries $
      Map.adjust
        (\entry -> if fmap fst entry.runtime == Just run then entry {runtime = Nothing} else entry)
        run.jobId

completeJob :: Jobs -> JobRun -> TaskStatus -> JobResult -> IO ()
completeJob jobs run status result = do
  now <- getCurrentTime
  cancelled <- atomically $ do
    entries <- readTVar jobs.entries
    case lookupRun entries run of
      Just entry | taskIsLive entry.view.status && not (taskIsLive status) -> do
        -- A waiter that already ended cannot collect the report; relay it.
        waiting <- maybe (pure False) (turnIsLive jobs.tasks) entry.awaiter
        let (stopped, turns) = stopChildren now entries entry.children "parent job ended"
            completed =
              entry
                { view = entry.view {status = if entry.budgetExhausted then BudgetExhausted else status, result = Just result, finished = Just now},
                  noticeVersion = entry.noticeVersion + 1,
                  pendingNotice = if isNothing entry.view.spec.parent && isNothing entry.view.spec.monitor && not waiting then Just result.text else Nothing,
                  awaiter = if waiting then entry.awaiter else Nothing,
                  pendingMonitor = isJust entry.view.spec.monitor
                }
            notify parent = parent {childUpdates = Set.insert run parent.childUpdates}
            withParent = maybe stopped (\owner -> Map.adjust notify owner.jobId stopped) entry.view.spec.parent
        writeTVar jobs.entries (Map.insert run.jobId completed withParent)
        pure turns
      _ -> pure []
  stopTurns jobs cancelled

-- | A foreground turn waits for a root it admitted with @awaited@; the report
-- returns here instead of through a relay notice. If the turn stops waiting
-- first (cancelled, timed out, or the objective was replaced), the job becomes
-- an ordinary root again, so its report is still relayed.
awaitJob :: Jobs -> AgentTurnId -> JobRun -> IO (Either Text JobView)
awaitJob jobs turn run = mask $ \restore -> restore waitReport `onException` atomically release
  where
    waitReport = atomically $ do
      live <- turnIsLive jobs.tasks turn
      unless live (throwSTM TaskCancelled)
      entries <- readTVar jobs.entries
      case Map.lookup run.jobId entries of
        Just entry
          | entry.awaiter /= Just turn -> pure (Left "this turn is not waiting for that job")
          | entry.view.run /= run -> release >> pure (Left "the job's objective was replaced; its report will be relayed")
          | taskIsLive entry.view.status -> retry
          | otherwise -> do
              writeTVar jobs.entries (Map.insert run.jobId entry {awaiter = Nothing} entries)
              pure (Right entry.view)
        Nothing -> pure (Left "job not found")
    release = do
      closing <- readTVar jobs.closed
      modifyTVar' jobs.entries (Map.adjust (detach closing) run.jobId)
    -- A report nobody collected is relayed like any root's, unless the job
    -- was cancelled or shutdown already owns its notice.
    detach closing entry
      | entry.awaiter /= Just turn = entry
      | taskIsLive entry.view.status || closing || entry.view.status == Cancelled = entry {awaiter = Nothing}
      | otherwise = entry {awaiter = Nothing, pendingNotice = (.text) <$> entry.view.result}

-- | Book one completion against the job whose turn made it and every
-- ancestor, so a root's report covers its whole tree.
recordJobUsage :: Jobs -> AgentTurnId -> TokenUsage -> IO ()
recordJobUsage jobs turn usage = atomically $ do
  entries <- readTVar jobs.entries
  case entryForTurn entries turn of
    Just entry -> do
      let owners = entry.view.run.jobId : map (.view.run.jobId) (ancestors entries entry.view.spec.parent)
          book job = job {view = job.view {usage = addJobUsage usage job.view.usage}}
      writeTVar jobs.entries (foldr (Map.adjust book) entries owners)
    Nothing -> pure ()

reportJobProgress :: Jobs -> AgentTurnId -> Text -> IO Bool
reportJobProgress jobs turn body = atomically $ do
  entries <- readTVar jobs.entries
  case entryForTurn entries turn of
    Just entry | currentRuntime entry && taskIsLive entry.view.status && not (T.null (T.strip body)) && T.length body <= 40000 -> do
      let unchanged = entry.view.progress == Just body
          -- Progress is observable through task status and the parent's inbox,
          -- never a conversation publication. Only terminal results enqueue
          -- notices; in particular monitor progress must not bypass its policy.
          updated =
            entry
              { view = entry.view {progress = Just body}
              }
          notify parent = parent {childUpdates = Set.insert entry.view.run parent.childUpdates}
          withParent = if unchanged then entries else maybe entries (\owner -> Map.adjust notify owner.jobId entries) entry.view.spec.parent
      writeTVar jobs.entries (Map.insert entry.view.run.jobId updated withParent)
      pure True
    _ -> pure False

readJobInbox :: Jobs -> AgentTurnId -> IO [Value]
readJobInbox jobs turn = atomically $ do
  entries <- readTVar jobs.entries
  case entryForTurn entries turn of
    Just entry | currentRuntime entry && taskIsLive entry.view.status -> do
      writeTVar jobs.entries (Map.insert entry.view.run.jobId (entry {inbox = Seq.empty, childUpdates = Set.empty}) entries)
      pure (toList entry.inbox <> [object ["child_update" .= child.view] | run <- Set.toList entry.childUpdates, Just child <- [lookupRun entries run]])
    _ -> pure []

waitForChildren :: Jobs -> AgentTurnId -> [Int64] -> IO (Either Text JobWait)
waitForChildren jobs turn requested = atomically $ do
  live <- turnIsLive jobs.tasks turn
  unless live (throwSTM TaskCancelled)
  entries <- readTVar jobs.entries
  case entryForTurn entries turn of
    Just entry | currentRuntime entry && taskIsLive entry.view.status -> do
      let selected = if null requested then Set.toList entry.children else filter ((`elem` requested) . (.jobId)) (Set.toList entry.children)
          found = mapMaybe (lookupRun entries) selected
      if any (`notElem` map (.jobId) selected) requested || length found /= length selected
        then pure (Left "wait requires current children of this job")
        else
          if not (Seq.null entry.inbox)
            then pure (Right FeedbackPending)
            else
              if not (any (taskIsLive . (.view.status)) found)
                then pure (Right (ChildrenFinished (map (.view) found)))
                else retry
    _ -> throwSTM TaskCancelled

listJobs :: Jobs -> GroupId -> IO [JobView]
listJobs jobs group = map (.view) . filter ((== group) . (.view.spec.group)) . Map.elems <$> readTVarIO jobs.entries

lookupJob :: Jobs -> GroupId -> Int64 -> IO (Maybe JobView)
lookupJob jobs group identifier = do
  entries <- readTVarIO jobs.entries
  pure $ case Map.lookup identifier entries of
    Just entry | entry.view.spec.group == group -> Just entry.view
    _ -> Nothing

jobForTurn :: Jobs -> AgentTurnId -> IO (Maybe JobView)
jobForTurn jobs turn = fmap (.view) . (`entryForTurn` turn) <$> readTVarIO jobs.entries

authorizeJobStep :: Jobs -> AgentTurnId -> ExecutionStep -> IO Bool
authorizeJobStep jobs turn step = (== Admitted) <$> decideJobStep jobs turn step

-- | Live foreground turns are admitted. Background budgets are shared with the
-- root and survive replacement; stale generations never fall back to foreground.
decideJobStep :: Jobs -> AgentTurnId -> ExecutionStep -> IO Admission
decideJobStep jobs turn step = do
  now <- getCurrentTime
  atomically $ do
    live <- turnIsLive jobs.tasks turn
    if not live
      then pure Refused
      else do
        entries <- readTVar jobs.entries
        case entryForTurn entries turn of
          Nothing -> pure Admitted
          Just entry -> case lookupRun entries entry.root of
            Just root
              | currentRuntime entry
                  && taskIsLive entry.view.status
                  && taskIsLive root.view.status
                  && (step == ExecutionCheckpoint || entry.view.spec.deadline > now)
                  && all (taskIsLive . (.view.status)) (ancestors entries entry.view.spec.parent) -> do
                  let canReserve = case step of
                        ExecutionWork ReserveCall -> root.view.calls < treeToolCalls
                        ExecutionWork ReserveRound -> root.view.rounds < treeModelRounds
                        _ -> True
                      bump view = case step of
                        ExecutionWork ReserveCall -> view {calls = view.calls + 1}
                        ExecutionWork ReserveRound -> view {rounds = view.rounds + 1}
                        _ -> view
                      reserve = case step of ExecutionWork ReserveCall -> True; ExecutionWork ReserveRound -> True; _ -> False
                  if reserve && not canReserve
                    then do
                      writeTVar jobs.entries (foldr (Map.adjust (\job -> job {budgetExhausted = True})) entries (Set.toList (Set.fromList [entry.view.run.jobId, root.view.run.jobId])))
                      pure OverBudget
                    else do
                      when reserve $ writeTVar jobs.entries (foldr (Map.adjust (\job -> job {view = bump job.view})) entries (Set.toList (Set.fromList [entry.view.run.jobId, root.view.run.jobId])))
                      pure Admitted
            _ -> pure Refused

steerJob :: Jobs -> GroupId -> PrincipalId -> Maybe CanonicalMessageId -> Int64 -> Text -> IO (Either Text ())
steerJob jobs group actor source identifier note = atomically $ do
  entries <- readTVar jobs.entries
  case Map.lookup identifier entries of
    Just entry | entry.view.spec.group == group -> deliver entries entry
    _ -> pure (Left ("no " <> taskHandle identifier <> " in this conversation"))
  where
    deliver entries entry
      | not (taskIsLive entry.view.status) = pure (Left (taskHandle identifier <> " has already finished"))
      | T.null (T.strip note) = pure (Left "feedback is empty")
      | T.length note > 8000 = pure (Left "feedback exceeds 8000 characters")
      | Seq.length entry.inbox >= 256 = pure (Left "job feedback inbox is full")
      | otherwise = do
          let feedback = object ["author" .= actor, "source_message" .= source, "body" .= note]
          writeTVar jobs.entries (Map.insert identifier (appendInbox feedback entry) entries)
          pure (Right ())

cancelJob :: Jobs -> GroupId -> PrincipalId -> Bool -> Int64 -> Text -> IO (Either Text ())
cancelJob jobs group actor admin identifier reason = controlJob jobs group actor admin identifier $ \now entries entry ->
  let (stopped, turns) = stopChildren now entries (Set.singleton entry.view.run) reason
   in Right (stopped, turns)

replaceJob :: Jobs -> GroupId -> PrincipalId -> Bool -> Int64 -> Text -> IO (Either Text ())
replaceJob jobs group actor admin identifier objective = controlJob jobs group actor admin identifier $ \now entries entry ->
  if T.null (T.strip objective) || T.length objective > 40000
    then Left "invalid replacement objective"
    else
      let (stopped, turns) = stopChildren now entries entry.children "parent objective replaced"
          run = entry.view.run {generation = entry.view.run.generation + 1}
          spec = entry.view.spec {objective = T.strip objective}
          replacement =
            entry
              { view = entry.view {run, spec, status = Queued, progress = Nothing, result = Nothing, finished = Nothing},
                children = Set.empty,
                childUpdates = Set.empty,
                inbox = Seq.empty,
                noticeVersion = entry.noticeVersion + 1,
                pendingNotice = Nothing,
                pendingMonitor = False,
                noticeInFlight = False,
                root = if entry.root == entry.view.run then run else entry.root
              }
          updateParent parent = parent {children = Set.insert run (Set.delete entry.view.run parent.children)}
          withParent = maybe stopped (\parent -> Map.adjust updateParent parent.jobId stopped) spec.parent
       in Right (Map.insert identifier replacement withParent, turns <> maybe [] (pure . (.atrTurnId) . snd) entry.runtime)

controlJob :: Jobs -> GroupId -> PrincipalId -> Bool -> Int64 -> (UTCTime -> Map Int64 Entry -> Entry -> Either Text (Map Int64 Entry, [AgentTurnId])) -> IO (Either Text ())
controlJob jobs group actor admin identifier transition = do
  now <- getCurrentTime
  outcome <- atomically $ do
    entries <- readTVar jobs.entries
    case Map.lookup identifier entries of
      Just entry | entry.view.spec.group == group && (admin || entry.view.spec.principal == actor) && taskIsLive entry.view.status ->
        case transition now entries entry of
          Left detail -> pure (Left detail)
          Right (updated, turns) -> writeTVar jobs.entries updated >> pure (Right turns)
      _ -> pure (Left "live job not found or owner permission required")
  case outcome of
    Left detail -> pure (Left detail)
    Right turns -> stopTurns jobs turns >> pure (Right ())

noticeIsCurrent :: Jobs -> JobRun -> Int -> IO Bool
noticeIsCurrent jobs run version = do
  entries <- readTVarIO jobs.entries
  pure $ case lookupRun entries run of
    Just entry -> entry.noticeVersion == version && entry.view.status /= Cancelled
    _ -> False

lookupRun :: Map Int64 Entry -> JobRun -> Maybe Entry
lookupRun entries run = Map.lookup run.jobId entries >>= \entry -> if entry.view.run == run then Just entry else Nothing

liveRun :: Map Int64 Entry -> JobRun -> Bool
liveRun entries run = maybe False (taskIsLive . (.view.status)) (lookupRun entries run)

ancestors :: Map Int64 Entry -> Maybe JobRun -> [Entry]
ancestors entries parent = case parent >>= lookupRun entries of
  Just entry -> entry : ancestors entries entry.view.spec.parent
  Nothing -> []

entryForTurn :: Map Int64 Entry -> AgentTurnId -> Maybe Entry
entryForTurn entries turn = find ((== Just turn) . fmap ((.atrTurnId) . snd) . (.runtime)) (Map.elems entries)

currentRuntime :: Entry -> Bool
currentRuntime entry = fmap fst entry.runtime == Just entry.view.run

appendInbox :: Value -> Entry -> Entry
appendInbox note entry = entry {inbox = Seq.take 256 (entry.inbox |> note)}

stopChildren :: UTCTime -> Map Int64 Entry -> Set JobRun -> Text -> (Map Int64 Entry, [AgentTurnId])
stopChildren now entries children reason = Set.foldl' stop (entries, []) children
  where
    stop (current, turns) run = case lookupRun current run of
      Just entry
        | taskIsLive entry.view.status ->
            let (descendants, childTurns) = stopChildren now current entry.children reason
                stopped = entry {view = entry.view {status = Cancelled, result = Just (JobResult reason Nothing), finished = Just now}, pendingNotice = Nothing, pendingMonitor = isJust entry.view.spec.monitor, noticeVersion = entry.noticeVersion + 1}
                notify parent = parent {childUpdates = Set.insert run parent.childUpdates}
                withParent = maybe descendants (\parent -> Map.adjust notify parent.jobId descendants) entry.view.spec.parent
             in (Map.insert run.jobId stopped withParent, turns <> childTurns <> maybe [] (pure . (.atrTurnId) . snd) entry.runtime)
      _ -> (current, turns)

stopTurns :: Jobs -> [AgentTurnId] -> IO ()
stopTurns jobs = mapM_ (\turn -> void (cancelAgentTurnTask jobs.tasks turn))

bindJobNotice :: Jobs -> AgentTurnId -> JobRun -> Int -> IO ()
bindJobNotice jobs turn run version = atomically $ modifyTVar' jobs.notices (Map.insert turn (run, version))

detachJobNotice :: Jobs -> AgentTurnId -> IO ()
detachJobNotice jobs turn = atomically $ do
  notices <- readTVar jobs.notices
  modifyTVar' jobs.notices (Map.delete turn)
  forM_ (Map.lookup turn notices) $ \(run, _) -> releaseNoticeSTM jobs run

releaseJobNotice :: Jobs -> JobRun -> IO ()
releaseJobNotice jobs run = atomically (releaseNoticeSTM jobs run)

releaseNoticeSTM :: Jobs -> JobRun -> STM ()
releaseNoticeSTM jobs run = modifyTVar' jobs.entries $ Map.adjust (\entry -> if entry.view.run == run then entry {noticeInFlight = False} else entry) run.jobId

-- Called at the shared publication boundary, after checking the turn runtime.
authorizeJobPublication :: Jobs -> AgentTurnId -> IO Bool
authorizeJobPublication jobs turn = atomically $ do
  entries <- readTVar jobs.entries
  notices <- readTVar jobs.notices
  pure $ case entryForTurn entries turn of
    Just _ -> False
    Nothing -> case Map.lookup turn notices of
      Nothing -> True
      Just (run, version) -> case lookupRun entries run of
        Just entry -> entry.noticeVersion == version && entry.view.status /= Cancelled
        _ -> False

recordJobPublication :: Jobs -> AgentTurnId -> CanonicalMessageId -> IO ()
recordJobPublication jobs turn message = atomically $ do
  notices <- readTVar jobs.notices
  case Map.lookup turn notices of
    Nothing -> pure ()
    Just (run, _) -> modifyTVar' jobs.publications $ \published ->
      let updated = Map.insert message run published
       in if Map.size updated > 2048 then Map.deleteMin updated else updated

taskForReply :: Jobs -> GroupId -> CanonicalMessageId -> IO (Maybe Int64)
taskForReply jobs group message = atomically $ do
  published <- readTVar jobs.publications
  entries <- readTVar jobs.entries
  pure $ do
    run <- Map.lookup message published
    entry <- Map.lookup run.jobId entries
    if entry.view.spec.group == group then Just run.jobId else Nothing

allJobs :: Jobs -> IO [JobView]
allJobs jobs = map (.view) . Map.elems <$> readTVarIO jobs.entries

-- | Fence admission before cancelling work. Return root notices that have not
-- entered publication; already-running terminal notices keep their ownership.
closeJobs :: Jobs -> IO [JobView]
closeJobs jobs = do
  now <- getCurrentTime
  (notices, turns) <- atomically $ do
    closing <- readTVar jobs.closed
    if closing
      then pure ([], [])
      else do
        writeTVar jobs.closed True
        entries <- readTVar jobs.entries
        publishing <- Set.fromList . map fst . Map.elems <$> readTVar jobs.notices
        let live = Set.fromList [entry.view.run | entry <- Map.elems entries, taskIsLive entry.view.status]
            (stopped, turns) = stopChildren now entries live "服务重启，任务已中断；已发生的操作不会自动重试。"
            unbound entry = entry.noticeInFlight && Set.notMember entry.view.run publishing
            needsNotice entry = isNothing entry.view.spec.parent && (Set.member entry.view.run live || isJust entry.pendingNotice || entry.pendingMonitor || unbound entry)
            notices = [updated.view | entry <- Map.elems entries, needsNotice entry, Just updated <- [lookupRun stopped entry.view.run]]
            fence entry = entry {pendingNotice = Nothing, pendingMonitor = False, noticeVersion = entry.noticeVersion + if unbound entry then 1 else 0}
        writeTVar jobs.entries (fmap fence stopped)
        pure (notices, turns)
  stopTurns jobs turns
  pure notices

setJobBrowserAccess :: Jobs -> JobRun -> Bool -> IO ()
setJobBrowserAccess jobs run allowed = atomically $ do
  entries <- readTVar jobs.entries
  case lookupRun entries run of
    Just entry -> writeTVar jobs.entries (Map.insert run.jobId (entry {view = entry.view {browserAllowed = allowed}}) entries)
    _ -> pure ()

-- A reminder may retain queued occurrences, but runs only one at a time.
monitorAvailable :: Map Int64 Entry -> Entry -> Bool
monitorAvailable entries candidate = case candidate.view.spec.monitor of
  Nothing -> True
  Just monitor -> all available (Map.elems entries)
    where
      available other =
        other.view.run == candidate.view.run
          || fmap (.definitionId) other.view.spec.monitor /= Just monitor.definitionId
          || (other.view.status /= Running && isNothing other.runtime)

jobHasFeedback :: Jobs -> AgentTurnId -> IO Bool
jobHasFeedback jobs turn = do
  entries <- readTVarIO jobs.entries
  pure $ maybe False (not . Seq.null . (.inbox)) (entryForTurn entries turn)
