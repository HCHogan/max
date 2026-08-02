-- |
-- Episode-boundary memory extraction (the mem0 pattern, scheduled
-- like sleep): a cheap dedicated model reads a whole conversation
-- window plus the currently stored memories and emits a JSON list of
-- ADD / UPDATE / DELETE operations.  The main chat model keeps zero
-- responsibility for remembering — in practice it never calls the
-- memory tools on its own — while the explicit tools remain for
-- direct user requests ("记住X").
--
-- == Why episodes, not dispatches
--
-- This used to run after every dispatch, each pass seeing only that
-- turn's transcript.  Two dispatches forty seconds apart in one
-- support conversation each extracted their own half-overlapping
-- memory of it (prod ids 320/321) — fragmentation was structural,
-- not a prompt problem.  Now a dispatch merely arms a per-group idle
-- timer; group chatter pushes it back; when the group has been quiet
-- for 'idleSecs' (or 'volumeCap' messages pile up mid-conversation),
-- one extraction starts at the durable conversation cursor and reads
-- oldest-first pages — the whole arc, including how it ended.
--
-- The cursor also buys restart safety: 'memxWorker' starts by arming
-- any group with a newer ledger row, so an extraction lost to a crash
-- or redeploy is caught up, not dropped.
--
-- A failed extraction keeps the cursor where it was and is re-armed with
-- a short backoff.  Restart recovery remains the second line of defence.
module Max.MemoryExtract
  ( MemxScheduler,
    newMemxScheduler,
    armMemx,
    bumpMemx,
    memxWorker,
    dreamWorker,

    -- * Exposed for tests
    ExtractOp (..),
    memxPendingDeadline,
    parseOps,
    retryMemxAfterFailureAt,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (forever, when)
import Data.Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_, traverse_)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.List.NonEmpty (nonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time
  ( LocalTime (..),
    NominalDiffTime,
    TimeOfDay (..),
    TimeZone,
    addDays,
    addUTCTime,
    diffUTCTime,
    getCurrentTime,
    localDay,
    localTimeOfDay,
    localTimeToUTC,
    utc,
    utcToLocalTime,
  )
import Data.Traversable (for)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (conversationScopeFor, currentConversationRecall)
import Max.DB.ConversationCursor
  ( advanceCursor,
    advanceCursorBefore,
    loadCursor,
    memoryExtractCursor,
  )
import Max.DB.History
  ( HistoryItem (..),
    HistoryPage (..),
    LedgerItem (..),
    MessageCursor (..),
    fetchOldestPageAfter,
    hasMessagesAfter,
    pageEndCursor,
  )
import Max.DB.Session (listSessions)
import Max.Effects.LLM (ChatCtx (..), ChatMessage (..), ChatResponse (..), LLM, chat)
import Max.Embedding
  ( EmbedClient,
    embedTexts,
    makeEmbeddingRecord,
  )
import Max.MemoryStore
  ( ExpectedVersion (..),
    MemoryActor (..),
    MemoryActorKind (..),
    MemoryDraft (..),
    MemoryEvidence (..),
    MemoryId (..),
    MemoryItem (..),
    MemoryLifecycle (..),
    MemoryMaintenanceCandidate (..),
    MemoryMutationResult (..),
    MemoryScope (..),
    MemoryUpdate (..),
    MemoryVersion (..),
    archiveMemory,
    archiveVisibleMemory,
    countMemories,
    createMemory,
    evictOldest,
    findExactMemory,
    findNearestMemory,
    groupMemoryNamespace,
    listMemories,
    listMemoryMaintenanceCandidates,
    markMemoryEmbedded,
    memoryNamespace,
    parseScope,
    scopeText,
    updateMemory,
    updateVisibleMemory,
    userMemoryNamespace,
  )
import Max.Prompt (renderHistoryLine)
import Max.Session (Session (..), SessionRegistry, loadSession, readSession)
import Max.Time (fmtDate)
import Max.Tools.Memory (checkContent, maxMemoriesPerScope)
import Max.Util (catchSync, trySync)
import OneBot.Types (GroupId (..))

-- | One operation the extractor model may emit.
data ExtractOp
  = OpAdd !Text !(Maybe Int64) !Text -- scope, user_id (scope=user), content
  | OpUpdate !MemoryId !MemoryVersion !Text
  | OpDelete !MemoryId !MemoryVersion
  deriving stock (Show, Eq)

instance FromJSON ExtractOp where
  parseJSON = withObject "op" $ \o -> do
    action <- o .: "action"
    case action :: Text of
      "add" -> OpAdd <$> o .: "scope" <*> o .:? "user_id" <*> o .: "content"
      "update" -> OpUpdate <$> o .: "id" <*> o .: "version" <*> o .: "content"
      "delete" -> OpDelete <$> o .: "id" <*> o .: "version"
      other -> fail ("unknown action: " <> T.unpack other)

--------------------------------------------------------------------------------
-- Scheduler: precise per-group wakeups, no polling.

-- | Group's raw id → (deadline, messages seen while armed).  The
-- version counter wakes the worker when a deadline is inserted or
-- moved — 'registerDelay' alone would sleep through an earlier one.
data MemxScheduler = MemxScheduler
  { msPending :: !(TVar (Map Int64 (UTCTime, Int))),
    msVersion :: !(TVar Int)
  }

newMemxScheduler :: IO MemxScheduler
newMemxScheduler = MemxScheduler <$> newTVarIO Map.empty <*> newTVarIO 0

-- | Quiet-for-this-long after bot involvement = the episode is over.
idleSecs :: Int
idleSecs = 600

-- | A conversation that never goes quiet still extracts once this
-- many messages accumulate, bounding episode latency and cost.
volumeCap :: Int
volumeCap = 60

-- | Raw-ledger page size for one extraction pass.  A backlog is drained in
-- oldest-first pages; this is a cost bound, never a history-loss boundary.
windowFetch :: Int
windowFetch = 120

-- | Windows smaller than this advance the cursor without an LLM
-- call — a two-line exchange isn't an episode.
minWindowMsgs :: Int
minWindowMsgs = 4

-- | Avoid a transient DB/provider failure turning into a hot loop while still
-- retrying well before the ordinary ten-minute idle boundary.
memxRetrySecs :: Int
memxRetrySecs = 60

-- | How many speakers' user-scope memories ride along as context.
maxSpeakerScopes :: Int
maxSpeakerScopes = 3

-- | A dispatch replied in this group: start (or restart) its idle
-- countdown.
armMemx :: MemxScheduler -> GroupId -> IO ()
armMemx sched (GroupId gid) = do
  now <- getCurrentTime
  let deadline = fromIntegral idleSecs `addTo` now
  atomically $ do
    modifyTVar' sched.msPending $
      Map.insertWith (\(d, _) (_, n) -> (d, n)) gid (deadline, 0)
    modifyTVar' sched.msVersion (+ 1)

-- | A group message arrived.  If the group is armed, the episode is
-- still going: push the deadline back — unless enough has piled up
-- that we extract now rather than let the window outgrow the fetch.
bumpMemx :: MemxScheduler -> GroupId -> IO ()
bumpMemx sched (GroupId gid) = do
  now <- getCurrentTime
  atomically $ do
    m <- readTVar sched.msPending
    for_ (Map.lookup gid m) $ \(_, n) -> do
      let entry
            | n + 1 >= volumeCap = (now, 0)
            | otherwise = (fromIntegral idleSecs `addTo` now, n + 1)
      writeTVar sched.msPending (Map.insert gid entry m)
      modifyTVar' sched.msVersion (+ 1)

-- | Re-arm a failed extraction without overwriting a newer schedule that may
-- have been installed while the extraction was running.
retryMemxAfterFailureAt :: MemxScheduler -> GroupId -> UTCTime -> IO ()
retryMemxAfterFailureAt sched (GroupId gid) now = atomically $ do
  modifyTVar' sched.msPending $
    Map.insertWith
      (\_ newer -> newer)
      gid
      (fromIntegral memxRetrySecs `addTo` now, 0)
  modifyTVar' sched.msVersion (+ 1)

-- | Test/diagnostic view that keeps the scheduler representation opaque.
memxPendingDeadline :: MemxScheduler -> GroupId -> IO (Maybe UTCTime)
memxPendingDeadline sched (GroupId gid) =
  fmap fst . Map.lookup gid <$> readTVarIO sched.msPending

addTo :: NominalDiffTime -> UTCTime -> UTCTime
addTo = addUTCTime

-- | App-lived worker: wait for the earliest deadline (or for the map
-- to change under us), fire due groups, repeat.  One crash logs and
-- the loop continues.
memxWorker ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- extractor profile name
  Maybe EmbedClient ->
  TimeZone ->
  SessionRegistry ->
  Text -> -- default model (session loads)
  MemxScheduler ->
  Eff es ()
memxWorker profile mEmbed tz sessions defaultModel sched = localDomain "memx" $ do
  recoverAtBoot
  forever $
    step `catchSync` \e ->
      logAttention "memx: round crashed" $ object ["error" .= T.pack (show e)]
  where
    step = do
      gid <- liftIO (awaitDue sched)
      result <-
        trySync $
          extractEpisode profile mEmbed tz sessions defaultModel (GroupId gid)
      case result of
        Right ExtractCaughtUp -> pure ()
        Right ExtractMore -> scheduleContinuation gid
        Right ExtractIncomplete -> scheduleRetry gid "extractor rejected the round"
        Left e -> scheduleRetry gid (T.pack (show e))

    scheduleContinuation gid = do
      now <- liftIO getCurrentTime
      liftIO (continueMemxAt sched (GroupId gid) now)
      logInfo "memx: backlog continuation scheduled" $ object ["group_id" .= gid]

    scheduleRetry gid reason = do
      now <- liftIO getCurrentTime
      liftIO (retryMemxAfterFailureAt sched (GroupId gid) now)
      logAttention "memx: episode retry scheduled" $
        object
          [ "group_id" .= gid,
            "retry_seconds" .= memxRetrySecs,
            "error" .= reason
          ]

    -- Ledger rows newer than the cursor with no timer running = an
    -- extraction a restart swallowed.  Arm rather than fire: the
    -- conversation may still be going, and the idle rule applies to
    -- it like any other.
    recoverAtBoot = do
      sessions' <- listSessions defaultModel
      for_ sessions' $ \s -> do
        let GroupId gid = s.groupId
            scope = conversationScopeFor s.groupId
        cursor0 <- loadCursor scope memoryExtractCursor
        cursor <- maybe (pure cursor0) (advanceCursorBefore scope memoryExtractCursor) s.clearedAt
        pending <- hasMessagesAfter scope cursor
        when pending $ do
          liftIO (armMemx sched s.groupId)
          logInfo "memx: recovered pending window" $ object ["group_id" .= gid]

data ExtractEpisodeResult
  = ExtractCaughtUp
  | ExtractMore
  | ExtractIncomplete

-- | Continue a successfully processed backlog immediately.  The next worker
-- pass re-reads the durable cursor, so restarts and competing updates remain
-- safe.
continueMemxAt :: MemxScheduler -> GroupId -> UTCTime -> IO ()
continueMemxAt sched (GroupId gid) now = atomically $ do
  modifyTVar' sched.msPending (Map.insert gid (now, 0))
  modifyTVar' sched.msVersion (+ 1)

-- | Block until one group's deadline has passed, then claim only that group.
-- Removing a whole due batch made the unstarted tail disappear if processing
-- the first group failed unexpectedly.
awaitDue :: MemxScheduler -> IO Int64
awaitDue sched = do
  now <- getCurrentTime
  (claimed, mNext, ver) <- atomically $ do
    m <- readTVar sched.msPending
    let (dueM, rest) = Map.partition (\(d, _) -> d <= now) m
    ver <- readTVar sched.msVersion
    case Map.lookupMin dueM of
      Just (gid, _) -> do
        writeTVar sched.msPending (Map.delete gid m)
        pure (Just gid, Nothing, ver)
      Nothing -> pure (Nothing, minimum <$> nonEmpty (map fst (Map.elems rest)), ver)
  case claimed of
    Just gid -> pure gid
    Nothing -> do
      case mNext of
        Nothing ->
          -- Nothing armed: sleep until somebody arms.
          atomically $ readTVar sched.msVersion >>= \v -> check (v /= ver)
        Just next -> do
          let micros = max 0 (ceiling (diffUTCTime next now * 1_000_000)) :: Integer
          delay <- registerDelay (fromIntegral (min micros 3_600_000_000))
          atomically $
            (readTVar delay >>= check)
              `orElse` (readTVar sched.msVersion >>= \v -> check (v /= ver))
      awaitDue sched

--------------------------------------------------------------------------------
-- One episode.

-- | Extract one oldest-first ledger page, then CAS the durable cursor to the
-- final row actually processed.  A failed LLM call or mutation leaves the
-- cursor untouched, so the exact same page is replayed.
extractEpisode ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  Maybe EmbedClient ->
  TimeZone ->
  SessionRegistry ->
  Text ->
  GroupId ->
  Eff es ExtractEpisodeResult
extractEpisode profile mEmbed tz sessions defaultModel g@(GroupId gid) = do
  t <- loadSession sessions defaultModel g
  s <- liftIO (readSession t)
  now <- liftIO getCurrentTime
  let conversation = conversationScopeFor g
  cursor0 <- loadCursor conversation memoryExtractCursor
  cursor <- maybe (pure cursor0) (advanceCursorBefore conversation memoryExtractCursor) s.clearedAt
  page <- fetchOldestPageAfter conversation cursor windowFetch
  let rows = [entry.history | entry <- page.items, entry.transcriptEligible]
      botInvolved = any (\h -> h.userId == h.selfId) rows
      incomplete reason = do
        logAttention "memx: extraction incomplete" $
          object ["group_id" .= gid, "error" .= reason]
        pure ExtractIncomplete
      complete = case pageEndCursor page of
        Nothing -> pure ExtractCaughtUp
        Just endCursor -> do
          advanced <- advanceCursor conversation memoryExtractCursor cursor endCursor
          stored <- if advanced then pure endCursor else loadCursor conversation memoryExtractCursor
          if stored < endCursor
            then incomplete "cursor compare-and-swap conflict"
            else do
              pending <- hasMessagesAfter conversation stored
              pure $ if pending then ExtractMore else ExtractCaughtUp
  if length rows < minWindowMsgs || not botInvolved
    then do
      logInfo "memx: window skipped" $
        object ["group_id" .= gid, "messages" .= length rows, "bot_involved" .= botInvolved]
      complete
    else do
      let selfId' = case rows of (h : _) -> h.selfId; [] -> 0
          render = renderHistoryLine tz selfId'
          transcript = T.intercalate "\n" (map render rows)
          speakers =
            take maxSpeakerScopes
              . map fst
              . sortOn (Down . snd)
              . Map.toList
              . Map.fromListWith (+)
              $ [(h.userId, 1 :: Int) | h <- rows, h.userId /= h.selfId]
      groupMems <- listMemories (groupMemoryNamespace conversation)
      userMemSets <- for speakers $ \u -> do
        ms <- listMemories (userMemoryNamespace conversation u)
        pure (u, ms)
      let msgs =
            [ MsgSystem extractorSystem,
              MsgUser (renderInput tz now gid groupMems userMemSets transcript)
            ]
      chat (ChatCtx "memx" (Just gid) Nothing) profile msgs [] >>= \case
        Left err -> incomplete ("chat: " <> err)
        Right (ToolCallsResp _ _ _) ->
          incomplete "unexpected tool calls"
        Right (ContentResp raw) -> case parseOps raw of
          Left err -> do
            logAttention "memx: bad ops json" $
              object ["error" .= err, "raw" .= T.take 400 raw]
            pure ExtractIncomplete
          Right [] -> do
            logInfo "memx: no ops" $ object ["group_id" .= gid, "messages" .= length rows]
            complete
          Right ops -> do
            let evidence = case page.items of
                  first : rest ->
                    let final = case reverse rest of
                          lastItem : _ -> lastItem
                          [] -> first
                     in RangeEvidence conversation first.cursor.ingestSeq final.cursor.ingestSeq
                  [] -> RangeEvidence conversation cursor.ingestSeq cursor.ingestSeq
            traverse_ (applyOp profile mEmbed gid evidence) (take 6 ops)
            -- Advance only after a complete pass: a crash or rejected
            -- response leaves the window unextracted and the worker
            -- re-arms it. Op-level dedup absorbs the rare replay.
            complete

-- | Parse the model's output into ops: strip code fences, find the
-- first @[@ .. last @]@, decode.
parseOps :: Text -> Either String [ExtractOp]
parseOps raw =
  let t = T.strip (stripFences (T.strip raw))
      sliced = case (T.findIndex (== '[') t, T.length t - 1) of
        (Just i, _) -> T.drop i (T.dropWhileEnd (/= ']') t)
        _ -> t
   in eitherDecode (LBS.fromStrict (TE.encodeUtf8 sliced))
  where
    stripFences s
      | "```" `T.isPrefixOf` s =
          T.intercalate "\n"
            . takeWhile (not . ("```" `T.isPrefixOf`))
            . drop 1
            $ T.lines s
      | otherwise = s

applyOp ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- extractor profile (reused for full-scope compaction)
  Maybe EmbedClient ->
  Int64 -> -- group id
  MemoryEvidence ->
  ExtractOp ->
  Eff es ()
applyOp profile mEmbed gid evidence = \case
  -- A user-scope add with no user_id has no defensible target in a
  -- multi-speaker window (the old code fell back to "whoever
  -- triggered the dispatch"; an episode has no such person).
  OpAdd "user" Nothing content ->
    logAttention "memx: user add without user_id" $ object ["content" .= T.take 80 content]
  OpAdd scopeRaw mUid content -> case parseScope scopeRaw of
    Nothing -> logAttention "memx: bad scope" $ object ["scope" .= scopeRaw]
    Just scope -> case checkContent content of
      Left err -> logAttention "memx: bad content" $ object ["error" .= err]
      Right c -> do
        let sid = case scope of
              ScopeGroup -> gid
              ScopeUser -> fromMaybe gid mUid -- unreachable Nothing: guarded above
            namespace = memoryNamespace conversation scope sid
        -- The prompt says "don't re-add near-duplicates", but small
        -- extractor models re-add anyway (observed on day one).
        -- Enforce in code: embed the candidate and skip when an
        -- existing memory in the same scope sits within the distance
        -- threshold.  pg_trgm can't do this — the DB is C-locale, so
        -- CJK text yields no trigrams at all (similarity() = 0).
        (mVec, mDup) <- findNearDup scope sid c
        case mDup of
          Just (did, dist) ->
            logInfo "memx: near-duplicate skipped" $
              object ["existing_id" .= did, "distance" .= dist, "content" .= c]
          Nothing -> do
            n <- countMemories namespace
            -- A full scope must not freeze learning (observed in
            -- prod: an active user pinned at the cap stops
            -- accumulating anything new).  Compact first — an LLM
            -- pass that merges overlapping entries and drops stale
            -- ones — and if that freed nothing, evict the
            -- least-recently-touched entry.  Either way the add
            -- proceeds.
            when (n >= maxMemoriesPerScope) $ do
              compactScope profile scope sid gid
              n' <- countMemories namespace
              when (n' >= maxMemoriesPerScope) $
                evictOldest actor namespace >>= \case
                  Just evicted ->
                    logInfo "memx: evicted oldest" $
                      object ["id" .= evicted.memId, "version" .= evicted.memVersion, "content" .= evicted.memContent]
                  Nothing -> pure ()
            saved <-
              createMemory
                actor
                namespace
                MemoryDraft
                  { draftContent = c,
                    draftLifecycle = MemoryActive,
                    draftCategory = Nothing,
                    draftEvidence = evidence
                  }
            -- Reuse the dedup vector so the new row is instantly
            -- searchable / dedupable (no worker lag window).
            case mVec of
              Just record -> do
                _ <-
                  markMemoryEmbedded
                    namespace
                    saved.memId
                    (ExpectedVersion saved.memVersion)
                    c
                    record
                pure ()
              Nothing -> pure ()
            logInfo "memx: added" $
              object ["id" .= saved.memId, "version" .= saved.memVersion, "scope" .= scopeRaw, "scope_id" .= sid, "content" .= c]
  OpUpdate mid version content -> case checkContent content of
    Left err -> logAttention "memx: bad content" $ object ["error" .= err]
    Right c -> do
      result <-
        updateVisibleMemory
          actor
          (currentConversationRecall conversation)
          mid
          (ExpectedVersion version)
          (MemoryUpdate c evidence)
      logInfo "memx: updated" $ object ["id" .= mid, "result" .= mutationResultText result, "content" .= c]
  OpDelete mid version -> do
    result <-
      archiveVisibleMemory
        actor
        (currentConversationRecall conversation)
        mid
        (ExpectedVersion version)
    logInfo "memx: archived" $ object ["id" .= mid, "result" .= mutationResultText result]
  where
    conversation = conversationScopeFor (GroupId gid)
    actor = MemoryActor ActorExtractor Nothing (Just "episode memory extraction")

    -- \| Returns (embedding of the candidate — reusable for the insert,
    -- nearest same-scope duplicate within 'dupDistance' if any).
    -- Fail-open: an embedding hiccup must not block memory writes; the
    -- fallback is exact-content match.
    -- Scoped to the current group for the same reason the reads are:
    -- another group's memory of this person is not a duplicate of one
    -- we're about to learn here, and treating it as one would silently
    -- drop the write.
    findNearDup scope sid c =
      let namespace = memoryNamespace conversation scope sid
       in case mEmbed of
            Nothing -> do
              duplicate <- findExactMemory namespace c
              let hit = (,0 :: Double) <$> duplicate
              pure (Nothing, hit)
            Just ec -> do
              evec <- liftIO (embedTexts ec [c])
              case evec of
                Left err -> do
                  logAttention "memx: dedup embed failed (fail-open)" $ object ["error" .= err]
                  pure (Nothing, Nothing)
                Right [v] -> do
                  case makeEmbeddingRecord ec c v of
                    Left err -> do
                      logAttention "memx: invalid dedup embedding (fail-open)" $ object ["error" .= err]
                      pure (Nothing, Nothing)
                    Right record -> do
                      nearest <- findNearestMemory namespace record
                      let hit = case nearest of
                            Just (did, dist) | dist < dupDistance -> Just (did, dist)
                            _ -> Nothing
                      pure (Just record, hit)
                Right _ -> pure (Nothing, Nothing)

-- | Cosine distance below which a candidate counts as "already
-- remembered".  Same-fact rewordings land well under this; genuinely
-- distinct facts about the same entity sit clearly above.
dupDistance :: Double
dupDistance = 0.15

mutationResultText :: MemoryMutationResult -> Text
mutationResultText MemoryMutationApplied {} = "applied"
mutationResultText MemoryMutationRejected = "rejected"

--------------------------------------------------------------------------------
-- Shrink passes: compaction (cap pressure) and dreaming (nightly).

-- | One LLM pass over a full scope under cap pressure: merge
-- overlapping entries and drop stale ones to free slots.  Best-effort:
-- a failed pass just logs, and the caller falls back to evicting the
-- oldest entry.
compactScope ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  MemoryScope ->
  Int64 ->
  -- | Current group; compaction sees exactly the slice the cap counts.
  Int64 ->
  Eff es ()
compactScope = shrinkScope "memx-compact" compactorSystem []

-- | A scope only gets dreamed once it holds this many entries.
dreamMinEntries :: Int
dreamMinEntries = 15

-- | Local hour the nightly pass runs at.
dreamHourLocal :: Int
dreamHourLocal = 4

-- | Nightly consolidation (the auto-dream pattern): once a day, at
-- 'dreamHourLocal' local time, every recently-touched scope holding
-- 'dreamMinEntries'+ entries gets a gentle shrink pass — merge
-- overlapping entries, drop superseded ones, rewrite relative time to
-- absolute dates.  The 49-hour change window covers a night missed to
-- downtime without re-dreaming dormant scopes forever; a repeat pass
-- over an already-tidy scope is a cheap "[]".
dreamWorker ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- extractor profile
  TimeZone ->
  Eff es ()
dreamWorker profile tz = localDomain "memx-dream" . forever $ do
  liftIO (sleepUntilHour tz dreamHourLocal)
  night `catchSync` \e ->
    logAttention "dream: night crashed" $ object ["error" .= T.pack (show e)]
  where
    night = do
      now <- liftIO getCurrentTime
      candidates <- listMemoryMaintenanceCandidates dreamMinEntries
      for_ candidates $ \candidate ->
        let scopeRaw = candidate.maintenanceScope
            sid = candidate.maintenanceSubjectId
            gid = candidate.maintenanceConversationId
            n = candidate.maintenanceCount
         in for_ (parseScope scopeRaw) $ \scope -> do
              logInfo "dream: scope" $
                object ["scope" .= scopeRaw, "scope_id" .= sid, "entries" .= n]
              shrinkScope
                "memx-dream"
                dreamerSystem
                ["今天是 " <> fmtDate tz now, ""]
                profile
                scope
                sid
                gid
                `catchSync` \e ->
                  logAttention "dream: scope crashed" $
                    object ["scope_id" .= sid, "error" .= T.pack (show e)]

-- | Sleep until the next occurrence of @hour:00@ local time.
sleepUntilHour :: TimeZone -> Int -> IO ()
sleepUntilHour tz hour = do
  now <- getCurrentTime
  let lt = utcToLocalTime tz now
      at = TimeOfDay hour 0 0
      nextLt
        | localTimeOfDay lt < at = LocalTime (localDay lt) at
        | otherwise = LocalTime (addDays 1 (localDay lt)) at
      next = localTimeToUTC tz nextLt
      micros = max 1_000_000 (ceiling (diffUTCTime next now * 1_000_000)) :: Integer
  threadDelay (fromIntegral micros)

-- | One shrink-only LLM pass over a full scope.  Reuses the
-- extraction op format/parser; @add@ ops are ignored — a shrink pass
-- must only ever shrink.
shrinkScope ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- ChatCtx label / log prefix
  Text -> -- system prompt
  [Text] -> -- extra input header lines
  Text -> -- profile
  MemoryScope ->
  Int64 ->
  Int64 ->
  Eff es ()
shrinkScope label sys header profile scope sid gid = do
  mems <- listMemories namespace
  let memLine m =
        T.pack (show m.memId.unMemoryId)
          <> "@v"
          <> T.pack (show m.memVersion.unMemoryVersion)
          <> " ("
          <> fmtDate utc m.memUpdatedAt
          <> "): "
          <> m.memContent
      input =
        T.unlines $
          header
            <> ( ("[memories — scope=" <> scopeText scope <> " id=" <> T.pack (show sid) <> "]")
                   : map memLine mems
               )
            <> ["", "输出操作 JSON 数组："]
  chat (ChatCtx label (Just gid) Nothing) profile [MsgSystem sys, MsgUser input] [] >>= \case
    Left err -> logAttention (label <> ": chat failed") $ object ["error" .= err]
    Right (ToolCallsResp _ _ _) ->
      logAttention (label <> ": unexpected tool calls") $ object []
    Right (ContentResp raw) -> case parseOps raw of
      Left err ->
        logAttention (label <> ": bad ops json") $
          object ["error" .= err, "raw" .= T.take 400 raw]
      Right ops -> do
        let shrinkOnly = [op | op <- ops, notAdd op]
            notAdd OpAdd {} = False
            notAdd _ = True
        traverse_ apply (take 12 shrinkOnly)
        logInfo (label <> ": scope done") $
          object
            [ "scope" .= scopeText scope,
              "scope_id" .= sid,
              "ops" .= length shrinkOnly
            ]
  where
    apply = \case
      OpAdd {} -> pure ()
      OpUpdate mid version content -> case checkContent content of
        Left err -> logAttention (label <> ": bad content") $ object ["error" .= err]
        Right c -> do
          result <-
            updateMemory
              actor
              namespace
              mid
              (ExpectedVersion version)
              (MemoryUpdate c (MaintenanceEvidence conversation label))
          logInfo (label <> ": merged") $ object ["id" .= mid, "result" .= mutationResultText result, "content" .= c]
      OpDelete mid version -> do
        result <- archiveMemory actor namespace mid (ExpectedVersion version)
        logInfo (label <> ": archived") $ object ["id" .= mid, "result" .= mutationResultText result]

    conversation = conversationScopeFor (GroupId gid)
    actor =
      MemoryActor
        (if label == "memx-dream" then ActorDreamer else ActorExtractor)
        Nothing
        (Just label)
    namespace =
      memoryNamespace
        conversation
        scope
        sid

dreamerSystem :: Text
dreamerSystem =
  T.unlines
    [ "你在夜间整理一个 QQ bot 的长期记忆库（关于某个群或某个人；每条带 id 和",
      "最后更新日期，今天的日期在输入头部）。做四类整理，能不动就不动：",
      "  - 同主题/重叠的条目 → 合并：对其中一条 update 成合并后的表述，其余 delete。",
      "  - 明显过时、或被更新的条目取代的 → delete。",
      "  - 条目内容里的相对时间（\"最近\"\"上周\"\"昨天\"）→ 按该条的更新日期换算，",
      "    update 成绝对日期。",
      "  - 互相矛盾的条目 → 保留较新的事实，update 完善它，delete 旧的。",
      "没什么可整理就输出 []。最多 12 个操作。合并后的 content 用第三人称陈述句，",
      "≤300 字，自包含。",
      "只输出 JSON 数组，只允许 update / delete：",
      "  {\"action\":\"update\",\"id\":5,\"version\":2,\"content\":\"...\"}",
      "  {\"action\":\"delete\",\"id\":5,\"version\":2}"
    ]

compactorSystem :: Text
compactorSystem =
  T.unlines
    [ "你在整理一个已满的长期记忆库（QQ bot 关于某个群或某个人的记忆，",
      "每条带 id 和最后更新日期）。目标是腾出空间同时尽量少丢信息：",
      "  - 相近/重叠/同主题的条目 → 合并：对其中一条 update 成合并后的表述，其余 delete。",
      "  - 明显过时、被后来条目取代、或已无价值的 → delete。",
      "  - 拿不准的保留。至少腾出 3 个位置，最多操作 12 条。",
      "  - 合并后的 content 用第三人称陈述句，≤300 字，自包含。",
      "只输出 JSON 数组，只允许 update / delete：",
      "  {\"action\":\"update\",\"id\":5,\"version\":2,\"content\":\"...\"}",
      "  {\"action\":\"delete\",\"id\":5,\"version\":2}"
    ]

--------------------------------------------------------------------------------
-- Prompt.

extractorSystem :: Text
extractorSystem =
  T.unlines
    [ "你是一个记忆提取器。输入是一段 QQ 群对话（多名成员参与，bot 的行名是 Max）",
      "和已存的长期记忆，输出是对记忆库的操作列表（JSON 数组），除 JSON 外不要输出任何东西。",
      "",
      "只提取【将来的对话还会用到的稳定信息】：",
      "  - 关于某个人的：身份/背景、长期偏好、专长、明确的约定或承诺 → scope=\"user\"（必须带 user_id，QQ号看行首名字后的标注或 [@#QQ号] 标记里的数字；认不出QQ号就不要提取）",
      "  - 关于这个群的：进行中的项目、群规矩/惯例、反复出现的梗 → scope=\"group\"",
      "不要提取：闲聊、情绪、一次性任务的细节、时效性内容、翻聊天记录就能查到的东西。",
      "",
      "规则：",
      "  - 大多数对话没有值得记的东西——那就输出 []。宁缺毋滥。",
      "  - 和已有记忆重复/相近 → 不要 add；内容有演进 → 用 update 改写那条。",
      "  - 已有记忆被对话明确证伪且无修订价值 → delete。",
      "  - content 用第三人称陈述句，≤300 字，自包含（不引用\"上文\"）。",
      "  - 涉及时间一律写绝对日期（输入头部有今天的日期）：\"昨天决定X\"要写成\"2026-07-29 决定X\"。",
      "  - 这是一整段对话，优先提炼它的结论/结局，而不是过程中的中间状态。",
      "  - 单次最多 6 个操作。",
      "",
      "操作格式：",
      "  {\"action\":\"add\",\"scope\":\"group\"|\"user\",\"user_id\":123,\"content\":\"...\"}",
      "  {\"action\":\"update\",\"id\":5,\"version\":2,\"content\":\"...\"}",
      "  {\"action\":\"delete\",\"id\":5,\"version\":2}"
    ]

renderInput :: TimeZone -> UTCTime -> Int64 -> [MemoryItem] -> [(Int64, [MemoryItem])] -> Text -> Text
renderInput tz now gid groupMems userMemSets transcript =
  T.unlines $
    concat
      [ ["今天是 " <> fmtDate tz now, ""],
        ["[existing memories — group_id=" <> T.pack (show gid) <> "]"],
        memLines groupMems,
        concat
          [ ["", "[existing memories — user_id=" <> T.pack (show u) <> "]"] <> memLines ms
          | (u, ms) <- userMemSets
          ],
        ["", "[conversation]", transcript, "", "输出操作 JSON 数组："]
      ]
  where
    memLines [] = ["(无)"]
    memLines ms =
      [ T.pack (show m.memId.unMemoryId)
          <> "@v"
          <> T.pack (show m.memVersion.unMemoryVersion)
          <> ": "
          <> m.memContent
      | m <- ms
      ]
