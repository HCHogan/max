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
    resultRouter,
    resultOrigin,
    otherOpenTasks,
    readObservationPage,
    bindResultRelay,
    bindReportRelay,
    bindMessageRelay,
    acquireGuestSlot,
    admitJob,
    admitJobWithAuthority,
    takeJobWork,
    attachJobTurn,
    attachAutomationTurn,
    detachJobTurn,
    completeJob,
    awaitJob,
    recordJobUsage,
    reportJobProgress,
    flushJobEvents,
    jobEventTask,
    waitForChildren,
    listJobs,
    lookupJob,
    jobForTurn,
    authorizeJobStep,
    decideJobStep,
    steerJob,
    steerJobFrom,
    tellParent,
    askParent,
    cancelJob,
    replaceJob,
    detachJobNotice,
    authorizeJobPublication,
    allJobs,
    closeJobs,
    setJobBrowserAccess,
  )
where

import Control.Concurrent.STM
import Control.Exception (finally, mask, onException)
import Control.Monad (forM, forM_, unless, void, when)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (find)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing, mapMaybe)
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Max.Context.Read (ReadCursor (..), ReadLane (..), renderObservationPage)
import Max.ConversationScope (conversationScopeFor, conversationStorageId)
import Max.Execution.Authority (CallAuthority, callIsActive, callIsCurrent, callMatchesTool)
import Max.Execution.Types (Admission (..), ExecutionStep (..), StepReservation (..))
import Max.LLM.Types (TokenUsage)
import Max.Node.Events qualified as Events
import Max.Node.Router qualified as Router
import Max.Platform.Types (CanonicalMessageId, PrincipalId)
import Max.Task.Policy (treeModelRounds, treeToolCalls)
import Max.Task.State (TaskStatus (..), taskIsLive)
import Max.Task.Types
import Max.Tasks (TaskCancelled (..), TaskRegistry, TurnRuntime, bindTurnDeadline, bindTurnEvents, cancelAgentTurnTask, lookupTurnEvents, turnAcceptsWork, turnEvents, turnIsLive, turnRuntimeAgentTurn, turnWasCancelled)
import Max.Tasks qualified as Tasks
import Max.ToolContext (ToolContext)
import Max.Turn.Types (AgentTurnId (..), AgentTurnRef (..))
import OneBot.Types (GroupId)

data JobWork = LaunchJob !JobView | RecordMonitorResult !Router.MonitorResult | RelayResult !Router.Relay | RelayReport !Router.ReportRelay | RelayMessage !Router.MessageRelay
  deriving stock (Eq, Show)

data ReportSource = NoReport | WaitingReport | PendingReport deriving stock (Eq)

data Entry = Entry
  { view :: !JobView,
    root :: !JobRun,
    guestTree :: !(Either AgentTurnId JobRun),
    runtime :: !(Maybe (JobRun, AgentTurnRef)),
    children :: !(Set JobRun),
    reportSource :: !ReportSource,
    events :: !Events.Task,
    parentEvents :: !(Maybe Events.Task),
    parentTurn :: !(Maybe AgentTurnId),
    question :: !(Maybe (TMVar Value)),
    deliveryVersion :: !Int,
    budgetExhausted :: !Bool,
    -- | The admitted agent call owns this report even before its wait registers.
    awaiter :: !(Maybe AgentTurnId)
  }

data Jobs = Jobs
  { entries :: !(TVar (Map Int64 Entry)),
    messageNotices :: !(TVar (Map AgentTurnId Router.MessageRelay)),
    closed :: !(TVar Bool),
    guestSlots :: !(TVar (Map (Either AgentTurnId JobRun) Int)),
    resultRouter :: !Router.Router,
    resultNotices :: !(TVar (Map AgentTurnId Router.Relay)),
    reportNotices :: !(TVar (Map AgentTurnId Router.ReportRelay)),
    childWaiters :: !(TVar (Map (AgentTurnId, Int64) Int)),
    tasks :: !TaskRegistry
  }

newJobs :: TaskRegistry -> IO Jobs
newJobs tasks = Jobs <$> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO False <*> newTVarIO Map.empty <*> Router.newRouter <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> newTVarIO Map.empty <*> pure tasks

-- | Admission never waits: a paused ancestor must not occupy the slot a
-- descendant is queued for. The release action is idempotent and survives job
-- retirement/replacement. Foreground guests and their children share a tree.
acquireGuestSlot :: Jobs -> AgentTurnId -> IO (Maybe (IO ()))
acquireGuestSlot jobs turn = atomically $ do
  entries <- readTVar jobs.entries
  slots <- readTVar jobs.guestSlots
  closing <- readTVar jobs.closed
  let tree = maybe (Left turn) (.guestTree) (entryForTurn entries turn)
      count = Map.findWithDefault 0 tree slots
  if closing || sum slots >= 32 || count >= 16
    then pure Nothing
    else do
      writeTVar jobs.guestSlots (Map.insert tree (count + 1) slots)
      released <- newTVar False
      pure . Just . atomically $ do
        done <- readTVar released
        unless done $ do
          writeTVar released True
          modifyTVar' jobs.guestSlots (Map.update (\n -> if n <= 1 then Nothing else Just (n - 1)) tree)

-- | Capture host-minted provenance and a revocation check. Retained relay
-- owners prevent the job identity from being pruned before publication.
resultOrigin :: Jobs -> TurnRuntime -> ToolContext -> IO Router.Origin
resultOrigin jobs runtime context = atomically $ do
  entries <- readTVar jobs.entries
  notices <- readTVar jobs.messageNotices
  resultNotices <- readTVar jobs.resultNotices
  reportNotices <- readTVar jobs.reportNotices
  target <- turnEvents runtime
  let turn = (turnRuntimeAgentTurn runtime).atrTurnId
      owner = case entryForTurn entries turn of
        Just entry -> Just entry.view.run
        Nothing -> case Map.lookup turn resultNotices of
          Just relay -> relay.origin.owner
          Nothing -> case Map.lookup turn reportNotices of
            Just relay -> Just relay.job.run
            Nothing -> (.job.run) <$> Map.lookup turn notices
      valid = do
        cancelled <- turnWasCancelled runtime
        closed <- readTVar jobs.closed
        current <- readTVar jobs.entries
        inherited <- maybe (pure True) Router.relayIsCurrent (Map.lookup turn resultNotices)
        reportCurrent <- maybe (pure True) Router.reportIsCurrent (Map.lookup turn reportNotices)
        messageCurrent <- maybe (pure True) Router.messageIsCurrent (Map.lookup turn notices)
        pure (not cancelled && not closed && inherited && reportCurrent && messageCurrent && maybe True (\run -> maybe False ((/= Cancelled) . (.view.status)) (lookupRun current run)) owner)
  pure Router.Origin {turn, owner, context, target, valid}

otherOpenTasks :: Jobs -> TurnRuntime -> IO [Tasks.OpenTask]
otherOpenTasks jobs = Tasks.otherOpenTasks jobs.tasks

readObservationPage :: Jobs -> GroupId -> Maybe AgentTurnId -> Int -> ReadCursor -> IO (Either Text Value)
readObservationPage jobs group caller budget cursor = case cursor.rcLane of
  Observation owner batch _ | caller == Just (AgentTurnId owner) && cursor.rcScope == conversationStorageId (conversationScopeFor group) -> do
    found <- Tasks.lookupTurnObservation jobs.tasks group (AgentTurnId owner) batch
    pure $ maybe (Left "node observation expired or is not visible to this task") (renderObservationPage cursor budget) found
  _ -> pure (Left "node observation belongs to another task or conversation")

bindResultRelay :: Jobs -> AgentTurnId -> Router.Relay -> IO ()
bindResultRelay jobs turn relay = atomically (modifyTVar' jobs.resultNotices (Map.insert turn relay))

bindReportRelay :: Jobs -> AgentTurnId -> Router.ReportRelay -> IO ()
bindReportRelay jobs turn relay = atomically (modifyTVar' jobs.reportNotices (Map.insert turn relay))

bindMessageRelay :: Jobs -> AgentTurnId -> Router.MessageRelay -> IO ()
bindMessageRelay jobs turn relay = atomically (modifyTVar' jobs.messageNotices (Map.insert turn relay))

-- | IDs come from the retained task identity sequence, never from model input.
-- Terminal entries can be discarded only after their live parent releases them.
admitJob :: Jobs -> Maybe AgentTurnId -> Int64 -> JobSpec -> IO (Either Text JobView)
admitJob = admitJobWithAuthority Nothing

admitJobWithAuthority :: Maybe CallAuthority -> Jobs -> Maybe AgentTurnId -> Int64 -> JobSpec -> IO (Either Text JobView)
admitJobWithAuthority authority jobs caller identifier requested = do
  callCurrent <- case (authority, caller) of
    (Nothing, _) -> pure True
    (Just call, Just turn) -> callIsCurrent call turn
    _ -> pure False
  now <- getCurrentTime
  atomically $ do
    activeCall <- case (authority, caller) of
      (Nothing, _) -> pure True
      (Just call, Just turn) -> callIsActive call turn
      _ -> pure False
    closing <- readTVar jobs.closed
    allowed <- maybe (pure True) (turnIsLive jobs.tasks) caller
    resultOwners <- Router.referencedOwners jobs.resultRouter
    current <- readTVar jobs.entries
    waiters <- readTVar jobs.childWaiters
    events <- Events.newNode >>= Events.newTask
    callerEvents <- maybe (pure Nothing) (lookupTurnEvents jobs.tasks) caller
    let awaitedChildren = Set.fromList [child | ((_, child), _) <- Map.toList waiters]
        owned job = Set.member job.view.run resultOwners || Set.member job.view.run.jobId awaitedChildren || taskIsLive job.view.status || isJust job.runtime || job.reportSource /= NoReport || isJust job.awaiter || maybe False (liveRun current) job.view.spec.parent
        ancestry = Set.fromList [parent.view.run | job <- Map.elems current, owned job, parent <- ancestors current job.view.spec.parent]
        retained job = owned job || Set.member job.view.run ancestry
        completed = sortOn (Down . (.view.created)) (filter (not . retained) (Map.elems current))
        kept = Map.filter retained current <> Map.fromList [(entry.view.run.jobId, entry) | entry <- take 256 completed]
        parents = ancestors kept requested.parent
        withinScope parent = parent.view.spec.group == requested.group && parent.view.spec.principal == requested.principal && Map.isSubmapOfBy (==) requested.grants parent.view.spec.grants
        deadline = minimum (addUTCTime 21600 now : requested.deadline : map (.view.spec.deadline) parents)
        spec = requested {deadline, objective = T.strip requested.objective}
        run = JobRun identifier 1
        root = maybe run (.root) (lookupRun kept =<< spec.parent)
        view = JobView run spec Queued Nothing Nothing 0 0 now True emptyJobUsage Nothing []
        awaiter = if spec.awaited then caller else Nothing
        guestTree = maybe (maybe (Right run) Left caller) (.guestTree) (lookupRun kept =<< spec.parent)
        parentEvents = maybe callerEvents (fmap (.events) . lookupRun kept) spec.parent
        newEntry = Entry view root guestTree Nothing Set.empty NoReport events parentEvents caller Nothing 0 False awaiter
        invalid detail = pure (Left detail)
    let parentAllowed owner = case lookupRun kept owner of
          Just parent -> taskIsLive parent.view.status || (parent.view.status /= Cancelled && currentRuntime parent && fmap ((.atrTurnId) . snd) parent.runtime == caller && maybe False (`callMatchesTool` "agent") authority)
          Nothing -> False
    if closing || not allowed || not callCurrent || not activeCall || Map.member identifier current
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
                    if maybe False (not . parentAllowed) spec.parent || not (all withinScope parents) || any ((== Cancelled) . (.view.status)) parents
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

-- | Launch requests stay on bounded job entries. All terminal deliveries use
-- router receipts, sharing capacity and ownership with detached native calls.
takeJobWork :: Jobs -> IO JobWork
takeJobWork jobs = atomically $ do
  readTVar jobs.closed >>= check . not
  flushReports jobs
  monitorResults <- Router.monitorOwners jobs.resultRouter
  entries <- readTVar jobs.entries
  takeReady monitorResults entries `orElse` (Router.takeDelivery jobs.resultRouter >>= \case Router.NativeResult relay -> pure (RelayResult relay); Router.JobReport relay -> pure (RelayReport relay); Router.ChildMessage relay -> pure (RelayMessage relay); Router.MonitorCompleted result -> pure (RecordMonitorResult result))
  where
    takeReady monitorResults entries = case find (\entry -> entry.view.status == Queued && isNothing entry.runtime && monitorAvailable monitorResults entries entry) (Map.elems entries) of
      Just entry -> do
        let running = entry {view = entry.view {status = Running}}
        writeTVar jobs.entries (Map.insert entry.view.run.jobId running entries)
        pure (LaunchJob running.view)
      Nothing -> retry

attachJobTurn :: Jobs -> JobRun -> AgentTurnRef -> IO Bool
attachJobTurn jobs run turn = atomically $ do
  entries <- readTVar jobs.entries
  case lookupRun entries run of
    Just entry | entry.view.status == Running && isNothing entry.runtime -> do
      bound <- bindTurnEvents jobs.tasks turn.atrTurnId entry.events
      when bound $ do
        _ <- bindTurnDeadline jobs.tasks turn.atrTurnId entry.view.spec.deadline
        writeTVar jobs.entries (Map.insert run.jobId (entry {runtime = Just (run, turn)}) entries)
      pure bound
    _ -> pure False

-- | Root automation shares the conversation's event log, while keeping job
-- identity, cancellation, grants and retained-call lifetime. Bind before the
-- root worker starts so queued cancellation cannot escape runtime ownership.
attachAutomationTurn :: Jobs -> JobRun -> AgentTurnRef -> Events.Task -> STM Bool
attachAutomationTurn jobs run turn target =
  ( do
      entries <- readTVar jobs.entries
      case lookupRun entries run of
        Just entry | entry.view.status == Running && isNothing entry.runtime && isJust entry.view.spec.monitor -> do
          exists <- lookupTurnEvents jobs.tasks turn.atrTurnId
          check (isJust exists)
          pending <- Events.peekAll entry.events
          Events.deliverAll ((target, Events.Fired (Events.Occurrence run entry.view.spec)) : [(target, event.body) | event <- pending]) >>= check
          Events.close entry.events
          _ <- bindTurnDeadline jobs.tasks turn.atrTurnId entry.view.spec.deadline
          writeTVar jobs.entries (Map.insert run.jobId entry {events = target, runtime = Just (run, turn)} entries)
          pure True
        _ -> pure False
  )
    `orElse` pure False

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
        waiting <- hasReportWaiter jobs entry
        let (stopped, turns) = if status == Cancelled then stopChildren now entries entry.children "parent job cancelled" else (entries, [])
            completed =
              entry
                { view = entry.view {status = if entry.budgetExhausted then BudgetExhausted else status, result = Just result, finished = Just now},
                  reportSource = if waiting && isNothing entry.view.spec.monitor then WaitingReport else PendingReport,
                  awaiter = if waiting then entry.awaiter else Nothing
                }
        writeTVar jobs.entries (Map.insert run.jobId completed stopped)
        Router.closeTask jobs.resultRouter entry.events
        flushReports jobs
        pure turns
      _ -> pure []
  stopTurns jobs cancelled

hasReportWaiter :: Jobs -> Entry -> STM Bool
hasReportWaiter jobs entry = do
  waiters <- readTVar jobs.childWaiters
  let turns = maybe [] pure entry.awaiter <> [turn | ((turn, child), _) <- Map.toList waiters, child == entry.view.run.jobId]
  or <$> mapM (turnIsLive jobs.tasks) turns

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
              writeTVar jobs.entries (Map.insert run.jobId entry {awaiter = Nothing, reportSource = NoReport} entries)
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
      | otherwise = entry {awaiter = Nothing, reportSource = if isJust entry.view.result then PendingReport else NoReport}

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
      -- Status progress is not a message. Children use ChildSaid for that.
      let updated = entry {view = entry.view {progress = Just body}}
      writeTVar jobs.entries (Map.insert entry.view.run.jobId updated entries)
      pure True
    _ -> pure False

-- Unaccepted reports retain one bounded source slot in their job entry. Once
-- admitted, the router owns them through observation or frontend relay.
flushJobEvents :: Jobs -> AgentTurnId -> STM ()
flushJobEvents jobs _ = flushReports jobs

flushReports :: Jobs -> STM ()
flushReports jobs = do
  Router.flush jobs.resultRouter
  entries <- readTVar jobs.entries
  updated <- forM (Map.toList entries) $ \(identifier, original) -> do
    waiting <- if original.reportSource == WaitingReport then hasReportWaiter jobs original else pure False
    let entry = if original.reportSource == WaitingReport && not waiting then original {reportSource = PendingReport, awaiter = Nothing} else original
    if entry.reportSource /= PendingReport
      then pure (identifier, entry)
      else do
        let valid = do
              current <- readTVar jobs.entries
              open <- maybe (pure False) Events.isOpen entry.parentEvents
              pure $ case lookupRun current entry.view.run of
                Just latest -> latest.deliveryVersion == entry.deliveryVersion && latest.view.status == entry.view.status && (isJust entry.view.spec.monitor || latest.view.status /= Cancelled || open)
                Nothing -> False
        accepted <- case entry.view.spec.monitor of
          Just _ -> Router.deliverMonitorResult jobs.resultRouter entry.view valid
          Nothing -> Router.deliverReport jobs.resultRouter entry.view entry.parentEvents valid (reportMessages jobs entry.view.run)
        pure (identifier, entry {reportSource = if accepted then NoReport else PendingReport})
  modifyTVar' jobs.entries (\current -> foldr (\(identifier, update) -> Map.adjust (\entry -> entry {reportSource = update.reportSource, awaiter = update.awaiter}) identifier) current updated)

jobEventTask :: Jobs -> AgentTurnId -> STM (Maybe Events.Task)
jobEventTask jobs turn = do
  entries <- readTVar jobs.entries
  pure $ case entryForTurn entries turn of
    Just entry | currentRuntime entry && taskIsLive entry.view.status -> Just entry.events
    _ -> Nothing

waitForChildren :: Jobs -> AgentTurnId -> [Int64] -> IO (Either Text JobWait)
waitForChildren jobs turn requested = mask $ \restore -> do
  selected <- atomically $ do
    found <- childrenFor requested
    case found of
      Left detail -> pure (Left detail)
      Right children -> do
        let identifiers = map (.view.run.jobId) children
        modifyTVar' jobs.childWaiters (\waiters -> foldr (\child -> Map.insertWith (+) (turn, child) 1) waiters identifiers)
        pure (Right identifiers)
  case selected of
    Left detail -> pure (Left detail)
    Right identifiers -> do
      let release abandoned = atomically $ do
            modifyTVar' jobs.childWaiters (\waiters -> foldr (\child -> Map.update (\n -> if n <= 1 then Nothing else Just (n - 1)) (turn, child)) waiters identifiers)
            entries <- readTVar jobs.entries
            updated <- forM identifiers $ \identifier -> case Map.lookup identifier entries of
              Just child | child.reportSource == WaitingReport || child.awaiter == Just turn -> do
                let released = if child.awaiter == Just turn then child {awaiter = Nothing} else child
                waiting <- hasReportWaiter jobs released
                let source = if child.reportSource /= WaitingReport then child.reportSource else if not abandoned then NoReport else if waiting then WaitingReport else PendingReport
                pure (Just (identifier, released {reportSource = source}))
              _ -> pure Nothing
            writeTVar jobs.entries (Map.fromList (mapMaybe id updated) <> entries)
          await =
            atomically $
              (if null identifiers then pure (Right []) else childrenFor identifiers) >>= \case
                Left detail -> pure (Left detail)
                Right found -> if any (taskIsLive . (.view.status)) found then retry else pure (Right (ChildrenFinished (map (.view) found)))
      result <- restore await `onException` release True
      release (case result of Left _ -> True; Right _ -> False)
      pure result
  where
    childrenFor identifiers = do
      live <- turnIsLive jobs.tasks turn
      closing <- readTVar jobs.closed
      unless (live && not closing) (throwSTM TaskCancelled)
      entries <- readTVar jobs.entries
      case entryForTurn entries turn of
        Just entry | currentRuntime entry && entry.view.status /= Cancelled -> do
          let selected = if null identifiers then Set.toList entry.children else filter ((`elem` identifiers) . (.jobId)) (Set.toList entry.children)
              found = mapMaybe (lookupRun entries) selected
          pure $ if any (`notElem` map (.jobId) selected) identifiers || length found /= length selected then Left "wait requires current children of this job" else Right found
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
    live <- (if step == ExecutionWork CheckOnly then turnIsLive else turnAcceptsWork) jobs.tasks turn
    closing <- readTVar jobs.closed
    if not live || closing
      then pure Refused
      else do
        entries <- readTVar jobs.entries
        case entryForTurn entries turn of
          Nothing -> pure Admitted
          Just entry -> case lookupRun entries entry.root of
            Just root
              | currentRuntime entry
                  && (taskIsLive entry.view.status || (step == ExecutionWork CheckOnly && entry.view.status /= Cancelled))
                  && root.view.status /= Cancelled
                  && (step == ExecutionCheckpoint || entry.view.spec.deadline > now)
                  && all ((/= Cancelled) . (.view.status)) (ancestors entries entry.view.spec.parent) -> do
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

-- | Ordinary external steering does not impersonate an answer from the parent.
steerJob :: Jobs -> GroupId -> PrincipalId -> Maybe CanonicalMessageId -> Int64 -> Text -> IO (Either Text ())
steerJob jobs = steerJobFrom jobs Nothing

steerJobFrom :: Jobs -> Maybe AgentTurnId -> GroupId -> PrincipalId -> Maybe CanonicalMessageId -> Int64 -> Text -> IO (Either Text ())
steerJobFrom jobs sender group actor source identifier note = atomically $ do
  entries <- readTVar jobs.entries
  notices <- readTVar jobs.messageNotices
  case Map.lookup identifier entries of
    Just entry
      | entry.view.spec.group == group ->
          if not (taskIsLive entry.view.status)
            then pure (Left (taskHandle identifier <> " has already finished"))
            else
              if T.null (T.strip note)
                then pure (Left "feedback is empty")
                else
                  if T.length note > 8000
                    then pure (Left "feedback exceeds 8000 characters")
                    else do
                      relayAnswer <- case sender >>= (`Map.lookup` notices) of
                        Just relay | relay.job.run == entry.view.run -> do
                          current <- Router.messageIsCurrent relay
                          if current then relay.answersPendingQuestion else pure False
                        _ -> pure False
                      let feedback = object ["author" .= actor, "source_message" .= source, "body" .= note]
                          fromParent =
                            relayAnswer || case sender of
                              Nothing -> False
                              Just turn -> case entry.view.spec.parent of
                                Just parent -> maybe False (\owner -> currentRuntime owner && owner.view.run == parent) (entryForTurn entries turn)
                                Nothing -> entry.parentTurn == Just turn
                      answering <- case entry.question of
                        Just reply | fromParent -> isEmptyTMVar reply
                        _ -> pure False
                      -- An answer settles the question future. It is still logged, but is
                      -- not another interrupt that would pause the guest receiving it.
                      let noteToParent = "[子任务收到直接 steering] " <> TE.decodeUtf8 (LBS.toStrict (encode feedback))
                      accepted <-
                        ( do
                            Events.deliver entry.events (if answering then Events.Settled "agent_ask" feedback [] else Events.Steered feedback) >>= check
                            unless fromParent $ deliverChildMessage jobs entry noteToParent Events.Normal (pure False) >>= check
                            pure True
                        )
                          `orElse` pure False
                      when (accepted && answering) $ forM_ entry.question (\reply -> putTMVar reply feedback)
                      pure (if accepted then Right () else Left "job event log is full or its task has ended")
    _ -> pure (Left ("no " <> taskHandle identifier <> " in this conversation"))

-- | The router owns each accepted message until observation, folding into
-- the final report, or an individual frontend relay.
tellParent :: Jobs -> AgentTurnId -> Text -> Bool -> IO (Either Text ())
tellParent jobs turn text urgent = atomically $ do
  live <- turnIsLive jobs.tasks turn
  entries <- readTVar jobs.entries
  case entryForTurn entries turn of
    Just entry | live && currentRuntime entry && taskIsLive entry.view.status -> do
      routeMessage jobs entry text urgent (pure False)
    _ -> pure (Left "message requires a current agent")

askParent :: Jobs -> AgentTurnId -> Text -> IO (Either Text Value)
askParent jobs turn text = mask $ \restore -> do
  registered <- atomically $ do
    live <- turnIsLive jobs.tasks turn
    entries <- readTVar jobs.entries
    case entryForTurn entries turn of
      Just entry | live && currentRuntime entry && taskIsLive entry.view.status && isNothing entry.question -> do
        reply <- newEmptyTMVar
        let answers = do
              current <- readTVar jobs.entries
              pure (maybe False ((== Just reply) . (.question)) (lookupRun current entry.view.run))
        outcome <- routeMessage jobs entry text True answers
        case outcome of
          Left err -> pure (Left err)
          Right () -> do
            modifyTVar' jobs.entries (Map.adjust (\current -> current {question = Just reply}) entry.view.run.jobId)
            pure (Right (entry.view.run, reply))
      _ -> pure (Left "ask requires a current agent without another pending question")
  case registered of
    Left err -> pure (Left err)
    Right (run, reply) ->
      restore
        ( atomically $ do
            live <- turnIsLive jobs.tasks turn
            entries <- readTVar jobs.entries
            case lookupRun entries run of
              Just entry | live && currentRuntime entry && taskIsLive entry.view.status -> Right <$> readTMVar reply
              _ -> pure (Left "asking agent ended or was replaced")
        )
        `finally` atomically (modifyTVar' jobs.entries (Map.adjust (\entry -> if entry.view.run == run && entry.question == Just reply then entry {question = Nothing} else entry) run.jobId))

routeMessage :: Jobs -> Entry -> Text -> Bool -> STM Bool -> STM (Either Text ())
routeMessage jobs entry text urgent answers
  | T.null (T.strip text) || T.length text > 8000 = pure (Left "message must contain 1..8000 characters")
  | otherwise = do
      accepted <- deliverChildMessage jobs entry text (if urgent then Events.Urgent else Events.Normal) answers
      pure (if accepted then Right () else Left "parent event or relay buffer is full")

deliverChildMessage :: Jobs -> Entry -> Text -> Events.Urgency -> STM Bool -> STM Bool
deliverChildMessage jobs entry text urgency answers =
  Router.deliverMessage jobs.resultRouter entry.view entry.parentEvents text urgency valid foldIntoReport answers
  where
    valid = do
      entries <- readTVar jobs.entries
      pure $ case lookupRun entries entry.view.run of
        Just current -> current.deliveryVersion == entry.deliveryVersion && current.view.status /= Cancelled
        Nothing -> False
    foldIntoReport = modifyTVar' jobs.entries (Map.adjust (\current -> if current.view.run == entry.view.run then current {view = current.view {messages = boundedMessages (current.view.messages <> [text])}} else current) entry.view.run.jobId)

reportMessages :: Jobs -> JobRun -> STM [Text]
reportMessages jobs run = maybe [] (.view.messages) . (`lookupRun` run) <$> readTVar jobs.entries

boundedMessages :: [Text] -> [Text]
boundedMessages = reverse . fit 32768 . take 50 . reverse
  where
    fit _ [] = []
    fit remaining (text : rest)
      | bytes <= remaining = text : fit (remaining - bytes) rest
      | otherwise = []
      where
        bytes = BS.length (TE.encodeUtf8 text) + 1

cancelJob :: Jobs -> GroupId -> PrincipalId -> Bool -> Int64 -> Text -> IO (Either Text ())
cancelJob jobs group actor admin identifier reason = controlJob jobs group actor admin identifier $ \now entries entry _ ->
  let (stopped, turns) = stopChildren now entries (Set.singleton entry.view.run) reason
   in Right (stopped, turns)

replaceJob :: Jobs -> GroupId -> PrincipalId -> Bool -> Int64 -> Text -> IO (Either Text ())
replaceJob jobs group actor admin identifier objective = controlJob jobs group actor admin identifier $ \now entries entry freshEvents ->
  if T.null (T.strip objective) || T.length objective > 40000
    then Left "invalid replacement objective"
    else
      let (stopped, turns) = stopChildren now entries entry.children "parent objective replaced"
          run = entry.view.run {generation = entry.view.run.generation + 1}
          spec = entry.view.spec {objective = T.strip objective}
          replacement =
            entry
              { view = entry.view {run, spec, status = Queued, progress = Nothing, result = Nothing, finished = Nothing, messages = []},
                children = Set.empty,
                reportSource = NoReport,
                events = freshEvents,
                question = Nothing,
                deliveryVersion = entry.deliveryVersion + 1,
                root = if entry.root == entry.view.run then run else entry.root
              }
          updateParent parent = parent {children = Set.insert run (Set.delete entry.view.run parent.children)}
          withParent = maybe stopped (\parent -> Map.adjust updateParent parent.jobId stopped) spec.parent
       in Right (Map.insert identifier replacement withParent, turns <> maybe [] (pure . (.atrTurnId) . snd) entry.runtime)

controlJob :: Jobs -> GroupId -> PrincipalId -> Bool -> Int64 -> (UTCTime -> Map Int64 Entry -> Entry -> Events.Task -> Either Text (Map Int64 Entry, [AgentTurnId])) -> IO (Either Text ())
controlJob jobs group actor admin identifier transition = do
  now <- getCurrentTime
  outcome <- atomically $ do
    routed <- Router.referencedOwners jobs.resultRouter
    entries <- readTVar jobs.entries
    case Map.lookup identifier entries of
      Just entry | entry.view.spec.group == group && (admin || entry.view.spec.principal == actor) && controllable routed entries entry -> do
        fresh <- Events.newNode >>= Events.newTask
        case transition now entries entry fresh of
          Left detail -> pure (Left detail)
          Right (updated, turns) -> writeTVar jobs.entries updated >> Router.closeTask jobs.resultRouter entry.events >> pure (Right turns)
      _ -> pure (Left "live job not found or owner permission required")
  case outcome of
    Left detail -> pure (Left detail)
    Right turns -> stopTurns jobs turns >> pure (Right ())
  where
    controllable routed entries entry = entry.view.status /= Cancelled && (Set.member entry.view.run routed || taskIsLive entry.view.status || isJust entry.runtime || entry.reportSource /= NoReport || any (\child -> taskIsLive child.view.status && any ((== entry.view.run) . (.view.run)) (ancestors entries child.view.spec.parent)) (Map.elems entries))

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

stopChildren :: UTCTime -> Map Int64 Entry -> Set JobRun -> Text -> (Map Int64 Entry, [AgentTurnId])
stopChildren now entries children reason = Set.foldl' stop (entries, []) children
  where
    stop (current, turns) run = case lookupRun current run of
      Just entry
        | entry.view.status /= Cancelled ->
            let (descendants, childTurns) = stopChildren now current entry.children reason
                stopped = entry {view = entry.view {status = Cancelled, result = Just (JobResult reason Nothing), finished = Just now}, reportSource = PendingReport, deliveryVersion = entry.deliveryVersion + 1}
             in (Map.insert run.jobId stopped descendants, turns <> childTurns <> maybe [] (pure . (.atrTurnId) . snd) entry.runtime)
      _ -> (current, turns)

stopTurns :: Jobs -> [AgentTurnId] -> IO ()
stopTurns jobs = mapM_ (\turn -> void (cancelAgentTurnTask jobs.tasks turn))

detachJobNotice :: Jobs -> AgentTurnId -> IO ()
detachJobNotice jobs turn = atomically $ do
  reports <- readTVar jobs.reportNotices
  forM_ (Map.lookup turn reports) (Router.releaseReport jobs.resultRouter)
  modifyTVar' jobs.reportNotices (Map.delete turn)
  relays <- readTVar jobs.resultNotices
  forM_ (Map.lookup turn relays) (Router.releaseRelay jobs.resultRouter)
  modifyTVar' jobs.resultNotices (Map.delete turn)
  notices <- readTVar jobs.messageNotices
  modifyTVar' jobs.messageNotices (Map.delete turn)
  forM_ (Map.lookup turn notices) (Router.releaseMessage jobs.resultRouter)

-- Called at the shared publication boundary, after checking the turn runtime.
authorizeJobPublication :: Jobs -> AgentTurnId -> IO Bool
authorizeJobPublication jobs turn = atomically $ do
  entries <- readTVar jobs.entries
  notices <- readTVar jobs.messageNotices
  relays <- readTVar jobs.resultNotices
  reports <- readTVar jobs.reportNotices
  case entryForTurn entries turn of
    Just entry -> pure (isJust entry.view.spec.monitor && currentRuntime entry && taskIsLive entry.view.status)
    Nothing -> case Map.lookup turn relays of
      Just relay -> Router.relayIsCurrent relay
      Nothing -> case Map.lookup turn reports of
        Just relay -> Router.reportIsCurrent relay
        Nothing -> maybe (pure True) Router.messageIsCurrent (Map.lookup turn notices)

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
        Router.flush jobs.resultRouter
        writeTVar jobs.closed True
        entries <- readTVar jobs.entries
        publishing <- Set.fromList . map (.job.run) . Map.elems <$> readTVar jobs.messageNotices
        messageOwners <- Router.messageOwners jobs.resultRouter
        reportOwners <- Router.reportOwners jobs.resultRouter
        monitorOwners <- Router.monitorOwners jobs.resultRouter
        publishingReports <- Set.fromList . map (.job.run) . Map.elems <$> readTVar jobs.reportNotices
        let live = Set.fromList [entry.view.run | entry <- Map.elems entries, taskIsLive entry.view.status]
            (stopped, turns) = stopChildren now entries live "服务重启，任务已中断；已发生的操作不会自动重试。"
            unbound entry = Set.member entry.view.run monitorOwners || (Set.member entry.view.run messageOwners && Set.notMember entry.view.run publishing) || (Set.member entry.view.run reportOwners && Set.notMember entry.view.run publishingReports)
            needsNotice entry = isNothing entry.view.spec.parent && (Set.member entry.view.run live || entry.reportSource == PendingReport || unbound entry)
            notices = [updated.view | entry <- Map.elems entries, needsNotice entry, Just updated <- [lookupRun stopped entry.view.run]]
            fence entry = entry {reportSource = NoReport, deliveryVersion = entry.deliveryVersion + if unbound entry then 1 else 0}
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
monitorAvailable :: Set JobRun -> Map Int64 Entry -> Entry -> Bool
monitorAvailable owned entries candidate = case candidate.view.spec.monitor of
  Nothing -> True
  Just monitor -> all available (Map.elems entries)
    where
      available other =
        other.view.run == candidate.view.run
          || fmap (.definitionId) other.view.spec.monitor /= Just monitor.definitionId
          || (other.view.status /= Running && isNothing other.runtime && other.reportSource == NoReport && Set.notMember other.view.run owned)
