-- |
-- Proactive-trigger intent classification: a cheap dedicated model
-- watches group chatter that neither @-mentions nor quotes the bot and
-- decides whether the bot should join in anyway — someone calling it
-- by name without an @, a follow-up to something it just said, or a
-- topic it can genuinely help with.  Directly-addressed messages skip
-- this entirely ("Max.Handler" dispatches those before we ever see
-- them).
--
-- __One question, and it is a gate rather than a route.__  This module used to
-- own a second classifier as well — @classifySupplement@, deciding whether a
-- message belonged to a turn already running.  ADR 007 §8 deleted it: "should
-- the expensive model see this at all" is answerable from cheap signals and
-- belongs here, whereas "which of the bot's activities is this about" is a
-- question about what somebody meant, and the model holding the conversation
-- answers it far better than four rendered history lines ever could.  Whatever
-- arrives while a turn is running now simply reaches that turn.
--
-- Shape: per-group pending buffers + one worker.  Messages accumulate
-- while the worker is busy (or during the debounce pause), so a burst
-- of chatter costs one classification and at most one reply — like a
-- person reading a run of messages before deciding to speak.  The
-- verdict is a hint, not a command: the main model keeps its @[silence]@
-- escape, so a false positive costs one dispatch, never a bad message.
--
-- Guard rails: per-group @!proactive@ toggle first, then the
-- classifier, then a throttle on its verdict.  The throttle is
-- kind-aware — the cooldown applies only to 'KindTopic' (the bot
-- inviting itself into a topic); 'KindCalled' and 'KindFollowup'
-- bypass it, because going deaf for the cooldown window right after
-- engaging someone is worse than chattiness ("干嘛" … user answers …
-- silence).  The hourly cap still applies to every kind — that is
-- the backstop against bot-to-bot loops.
module Max.Intent
  ( IntentConfig (..),
    IntentState,
    newIntentState,
    enqueueIntent,
    clearPendingIntent,
    noteBotActivity,
    intentWorker,
    classifyOnce,
    -- * Exposed for tests
    IntentVerdict (..),
    IntentKind (..),
    IntentRetry (..),
    claimIntentBatchAt,
    kindText,
    msgSignal,
    parseVerdict,
    Throttle (..),
    retryIntentBatchAt,
    throttleAllows,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Monad (forever)
import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
-- UTCTime itself rides in on the Effectful.Log re-export.
import Data.Time (NominalDiffTime, TimeZone, addUTCTime, diffUTCTime, getCurrentTime)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.History (HistoryItem (..), fetchRecentInGroup)
import Max.Dispatch (DispatchMessage (..), dispatchText)
import Max.Effects.LLM (ChatCtx (..), ChatMessage (..), ChatResponse (..), LLM, chat)
import Max.Prompt (renderHistoryLine)
import Max.Session (Session (..), SessionRegistry, loadSession, readSession)
import Max.Util (catchSync, trySync)
import Max.Platform.Types (CanonicalMessageId (..))
import OneBot.Types (GroupId (..), isPrivateChat)

-- | Resolved @intent.*@ config; presence enables the whole feature.
data IntentConfig = IntentConfig
  { -- | LLM profile the classifier calls (fast + cheap, e.g. a flash
    -- tier model).
    icProfile :: !Text,
    -- | Seconds after a proactive reply during which 'KindTopic'
    -- verdicts are suppressed (name-calls and conversation follow-ups
    -- are exempt, as are directly-addressed triggers).
    icCooldownSeconds :: !Int,
    -- | Hard cap on proactive replies per group per hour, all kinds.
    icMaxPerHour :: !Int,
    -- | How many recent group messages the classifier sees.
    icContextLines :: !Int
  }
  deriving stock (Show, Eq)

-- | Pending buffers + throttle bookkeeping, keyed by raw group id.
data IntentState = IntentState
  { isPending :: !(TVar (Map Int64 PendingIntent)),
    isPendingVersion :: !(TVar Int),
    isThrottle :: !(TVar (Map Int64 Throttle)),
    -- | When the bot last dispatched anything in a group (direct
    -- trigger, poke, or proactive) — the followup hot-window signal
    -- for 'passesGate'.
    isActivity :: !(TVar (Map Int64 UTCTime)),
    -- | When a group last spent its chatter-lane classification slot.
    isChatterLast :: !(TVar (Map Int64 UTCTime))
  }

data PendingIntent = PendingIntent
  { piReadyAt :: !UTCTime,
    piAttempt :: !Int,
    piMessages :: ![DispatchMessage]
  }

-- | Observable retry decision for logs and deterministic scheduler tests.
data IntentRetry
  = IntentRetryScheduled !UTCTime
  | IntentRetryExhausted
  deriving stock (Show, Eq)

-- | When this group last got a proactive reply, and the recent
-- trigger times inside the rolling hour window.
data Throttle = Throttle
  { thLast :: !UTCTime,
    thRecent :: ![UTCTime]
  }
  deriving stock (Show)

newIntentState :: IO IntentState
newIntentState =
  IntentState
    <$> newTVarIO Map.empty
    <*> newTVarIO 0
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty
    <*> newTVarIO Map.empty

--------------------------------------------------------------------------------
-- Heuristic gate: don't pay an LLM call for every batch of chatter.
--
-- Tuned against one week of production logs (2026-07-21/22, ~7500
-- unaddressed messages, 77 real triggers): 96% of classifier calls
-- returned "no trigger", and almost all recall lived in two cheap
-- signals — the bot's name in the text, and proximity to the bot's
-- own recent activity (followups virtually always arrive within
-- three minutes of an interaction).  Topic-kind triggers have no
-- cheap signal, so plain chatter gets a budgeted lane instead of a
-- blanket skip: at most one classification per group per
-- 'chatterCooldownSecs' — the bot checks the room every quarter hour
-- rather than reading every message, which is plenty for a kind
-- that's already cooldown- and cap-throttled.  Net effect in
-- simulation: ~4x fewer classifier calls.

-- | Substrings (lowercased match) that read as someone talking about
-- or to the bot.
signalNames :: [Text]
signalNames = ["max"]

-- | How long after a dispatch the group counts as "hot" — messages
-- in this window classify immediately (followup candidates).
followupHotSecs :: NominalDiffTime
followupHotSecs = 180

-- | Minimum spacing between chatter-lane classifications per group.
chatterCooldownSecs :: NominalDiffTime
chatterCooldownSecs = 900

-- | Does this rendered message text carry an immediate signal?
msgSignal :: Text -> Bool
msgSignal t = let low = T.toLower t in any (`T.isInfixOf` low) signalNames

-- | Record that the bot dispatched in a group just now (direct
-- trigger, poke wake, or proactive) — opens the followup hot window.
noteBotActivity :: IntentState -> GroupId -> IO ()
noteBotActivity st (GroupId gid) = do
  now <- getCurrentTime
  atomically $ modifyTVar' st.isActivity (Map.insert gid now)

-- | Decide whether a batch is worth an LLM classification; claims the
-- group's chatter-lane slot when that's the only reason to proceed.
passesGate :: IntentState -> Int64 -> UTCTime -> [DispatchMessage] -> IO Bool
passesGate st gid now batch = do
  acts <- readTVarIO st.isActivity
  let hot = case Map.lookup gid acts of
        Just t -> diffUTCTime now t <= followupHotSecs
        Nothing -> False
      named = any (msgSignal . dispatchText) batch
  if hot || named
    then pure True
    else atomically $ do
      m <- readTVar st.isChatterLast
      case Map.lookup gid m of
        Just t | diffUTCTime now t < chatterCooldownSecs -> pure False
        _ -> True <$ writeTVar st.isChatterLast (Map.insert gid now m)

-- | Newest messages a group buffer keeps while waiting for the
-- worker; older overflow is dropped (it is still visible to the
-- classifier as fetched context).
maxPendingPerGroup :: Int
maxPendingPerGroup = 30

-- | Wait this long after picking up a batch, then sweep in whatever
-- else arrived — a burst of rapid messages classifies once.
debounceMicros :: Int
debounceMicros = 2_000_000

-- | Intent is advisory rather than durable user work. Retry transient
-- classifier/DB failures in memory, but do not let a broken profile loop
-- forever. The original messages remain durable in chat history.
maxIntentAttempts :: Int
maxIntentAttempts = 3

intentRetryDelaySecs :: Int -> Int
intentRetryDelaySecs attempt
  | attempt <= 1 = 15
  | otherwise = 60

-- Keep this domain-specific while the project builds on @base-4.20@, whose
-- "Data.List" does not yet export @takeEnd@.  Do not grow another generic
-- list utility around it: a future base bump can replace this body directly.
capPendingMessages :: [DispatchMessage] -> [DispatchMessage]
capPendingMessages xs = drop (length xs - maxPendingPerGroup) xs

-- | Queue one unaddressed group message for classification.  Own
-- echoes and private chats never enqueue (a private message already
-- triggers directly).
enqueueIntent :: IntentState -> DispatchMessage -> IO ()
enqueueIntent st gm
  | gm.userId == gm.selfId || isPrivateChat gm.groupId = pure ()
  | otherwise = do
      now <- getCurrentTime
      let GroupId gid = gm.groupId
          fresh = PendingIntent now 0 [gm]
      atomically $ do
        modifyTVar' st.isPending $
          Map.insertWith
            (\new old -> old {piMessages = capPendingMessages (old.piMessages <> new.piMessages)})
            gid
            fresh
        modifyTVar' st.isPendingVersion (+ 1)

-- | Drop a group's pending buffer — called when a direct @/quote
-- trigger dispatches for that group, so the same messages can't also
-- produce a proactive reply (they reach the model as ambient context
-- of the direct turn anyway).
clearPendingIntent :: IntentState -> GroupId -> IO ()
clearPendingIntent st (GroupId gid) =
  atomically $ do
    modifyTVar' st.isPending (Map.delete gid)
    modifyTVar' st.isPendingVersion (+ 1)

-- | Is a proactive trigger of this kind currently allowed?  The
-- cooldown gates only 'KindTopic'; the hourly cap gates everything.
throttleAllows :: IntentConfig -> UTCTime -> IntentKind -> Maybe Throttle -> Bool
throttleAllows _ _ _ Nothing = True
throttleAllows cfg now kind (Just th) =
  cooldownOk && length (inWindow th.thRecent) < cfg.icMaxPerHour
  where
    cooldownOk =
      kind /= KindTopic
        || now `diffUTCTime` th.thLast >= fromIntegral cfg.icCooldownSeconds
    inWindow = filter (\t -> now `diffUTCTime` t < 3600)

recordTrigger :: IntentConfig -> UTCTime -> Maybe Throttle -> Throttle
recordTrigger _ now mth =
  Throttle
    { thLast = now,
      thRecent = now : filter (\t -> now `diffUTCTime` t < 3600) (maybe [] (.thRecent) mth)
    }

--------------------------------------------------------------------------------
-- Worker.

-- | App-lived classification loop.  Crashes of one round are logged
-- and never tear the worker down.
intentWorker ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  IntentConfig ->
  Text -> -- default persona ('AppConfig.persona'; sessions may override)
  Text -> -- default model name (for 'loadSession')
  TimeZone ->
  SessionRegistry ->
  ([DispatchMessage] -> Eff es ()) -> -- proactive dispatch of the whole batch, newest last (see 'Max.Handler.dispatchProactive')
  IntentState ->
  Eff es ()
intentWorker cfg defaultPersona defaultModel tz sessions dispatch st =
  localDomain "intent" . forever $
    step `catchSync` \e ->
      logAttention "intent: round crashed" $ object ["error" .= T.pack (show e)]
  where
    step = do
      (gid, attempt, batch0) <- liftIO (awaitIntentBatch st)
      -- Debounce: let the burst finish, then sweep the stragglers into
      -- this same round.
      liftIO (threadDelay debounceMicros)
      extra <- liftIO . atomically $ drainGroup st gid
      let batch = capPendingMessages (batch0 <> extra)
      case batch of
        [] -> pure ()
        (gm : _) -> do
          result <- trySync (classifyBatch gid attempt gm batch)
          case result of
            Right True -> pure ()
            Right False -> retryBatch gid attempt batch "classifier returned no usable verdict"
            Left e -> retryBatch gid attempt batch (T.pack (show e))

    retryBatch gid attempt batch reason = do
      now <- liftIO getCurrentTime
      decision <- liftIO (retryIntentBatchAt st gid attempt batch now)
      case decision of
        IntentRetryScheduled readyAt ->
          logAttention "intent: batch retry scheduled" $
            object
              [ "group_id" .= gid,
                "attempt" .= (attempt + 1),
                "ready_at" .= readyAt,
                "error" .= reason
              ]
        IntentRetryExhausted ->
          logAttention "intent: retry budget exhausted; dropping best-effort batch" $
            object
              [ "group_id" .= gid,
                "attempts" .= maxIntentAttempts,
                "batch" .= length batch,
                "error" .= reason
              ]

    classifyBatch gid attempt gm batch = do
      t <- loadSession sessions defaultModel gm.groupId
      s <- liftIO (readSession t)
      now <- liftIO getCurrentTime
      throttle <- liftIO (Map.lookup gid <$> readTVarIO st.isThrottle)
      -- Classify unless the feature is off for the group or even the
      -- least-throttled kind couldn't fire (hourly cap exhausted) —
      -- the kind-specific check happens on the verdict below.  The
      -- cap-block logs: it is rare, temporary, and looks exactly like
      -- a dead classifier from the outside (a production debugging
      -- session started from this very silence).  The feature-off and
      -- chatter-lane drops stay silent — those fire constantly and
      -- are working as configured.
      let enabled = fromMaybe True s.proactiveOverride
          capped = not (throttleAllows cfg now KindCalled throttle)
      gated <-
        if not enabled
          then pure False
          else
            if capped
              then do
                logInfo "intent: gate throttled" $
                  object
                    [ "group_id" .= gid,
                      "batch" .= length batch,
                      "reason" .= ("hourly cap" :: Text)
                    ]
                pure False
              else
                if attempt > 0
                  then pure True -- retry owns the gate claim from attempt zero
                  else liftIO (passesGate st gid now batch)
      if not gated
        then pure True
        else do
          let batchIds = Set.fromList [m | b <- batch, let CanonicalMessageId m = b.canonicalId]
          rows <- fetchRecentInGroup gid 0 s.clearedAt (cfg.icContextLines + length batch)
          let (news, ctx) = spanPartition (\h -> h.canonicalId `Set.member` batchIds) rows
              render = renderHistoryLine tz
          -- Rows for the batch can be missing only in pathological
          -- flood cases; classify anyway with whatever context we have.
          verdict <- classifyOnce (Just gid) cfg.icProfile (fromMaybe defaultPersona s.persona) (map render ctx) (map render news)
          case verdict of
            Nothing -> pure False
            Just v
              | not v.ivTrigger -> do
                  logInfo "intent: no trigger" $
                    object
                      [ "group_id" .= gid,
                        "batch" .= length batch,
                        "reason" .= v.ivReason
                      ]
                  pure True
              | not (throttleAllows cfg now v.ivKind throttle) -> do
                  logInfo "intent: trigger throttled" $
                    object
                      [ "group_id" .= gid,
                        "kind" .= kindText v.ivKind,
                        "reason" .= v.ivReason
                      ]
                  pure True
              | otherwise -> do
                  logInfo "intent: proactive trigger" $
                    object
                      [ "group_id" .= gid,
                        "batch" .= length batch,
                        "kind" .= kindText v.ivKind,
                        "reason" .= v.ivReason
                      ]
                  -- The whole batch, not just its newest message: the
                  -- dispatch triggers on the last one (the rest is
                  -- ambient context for a fresh turn), but if the turn
                  -- is absorbed into one already running, the earlier
                  -- lines must ride along in the note — the running
                  -- turn never re-reads history.
                  dispatch batch
                  liftIO . atomically . modifyTVar' st.isThrottle $ \m ->
                    Map.insert gid (recordTrigger cfg now (Map.lookup gid m)) m
                  liftIO (noteBotActivity st gm.groupId)
                  pure True

    -- Stable split: rows belonging to the batch vs. the rest, both in
    -- original chronological order.
    spanPartition p xs = (filter p xs, filter (not . p) xs)

-- | Non-blocking deterministic claim used by the worker scheduler and tests.
claimIntentBatchAt :: IntentState -> UTCTime -> IO (Maybe (Int64, Int, [DispatchMessage]))
claimIntentBatchAt st now = atomically $ do
  (claimed, _, _) <- claimSnapshot st now
  pure claimed

awaitIntentBatch :: IntentState -> IO (Int64, Int, [DispatchMessage])
awaitIntentBatch st = do
  now <- getCurrentTime
  (claimed, mNext, ver) <- atomically (claimSnapshot st now)
  case claimed of
    Just batch -> pure batch
    Nothing -> do
      case mNext of
        Nothing ->
          atomically $ readTVar st.isPendingVersion >>= \v -> check (v /= ver)
        Just readyAt -> do
          let micros = max 0 (ceiling (diffUTCTime readyAt now * 1_000_000)) :: Integer
          timer <- registerDelay (fromIntegral (min micros 3_600_000_000))
          atomically $
            (readTVar timer >>= check)
              `orElse` (readTVar st.isPendingVersion >>= \v -> check (v /= ver))
      awaitIntentBatch st

claimSnapshot ::
  IntentState ->
  UTCTime ->
  STM (Maybe (Int64, Int, [DispatchMessage]), Maybe UTCTime, Int)
claimSnapshot st now = do
  queued <- readTVar st.isPending
  ver <- readTVar st.isPendingVersion
  let ordered = sortOn (\(gid, p) -> (p.piReadyAt, gid)) (Map.toList queued)
      ready = filter (\(_, p) -> p.piReadyAt <= now) ordered
  case ready of
    ((gid, p) : _) -> do
      writeTVar st.isPending (Map.delete gid queued)
      pure (Just (gid, p.piAttempt, p.piMessages), Nothing, ver)
    [] -> pure (Nothing, (.piReadyAt) . snd <$> listToMaybe ordered, ver)

-- | Put a failed batch back behind a bounded delay. New messages that arrived
-- for the same group are merged behind it so chronology is preserved.
retryIntentBatchAt ::
  IntentState ->
  Int64 ->
  Int ->
  [DispatchMessage] ->
  UTCTime ->
  IO IntentRetry
retryIntentBatchAt st gid previousAttempt batch now = do
  let attempt = previousAttempt + 1
  if attempt >= maxIntentAttempts
    then pure IntentRetryExhausted
    else do
      let readyAt = addUTCTime (fromIntegral (intentRetryDelaySecs attempt)) now
          retried = PendingIntent readyAt attempt batch
      atomically $ do
        queued <- readTVar st.isPending
        let merged = case Map.lookup gid queued of
              Nothing -> retried
              Just newer ->
                retried
                  { piMessages =
                      capPendingMessages (retried.piMessages <> newer.piMessages)
                  }
        writeTVar st.isPending (Map.insert gid merged queued)
        modifyTVar' st.isPendingVersion (+ 1)
      pure (IntentRetryScheduled readyAt)

drainGroup :: IntentState -> Int64 -> STM [DispatchMessage]
drainGroup st gid = do
  m <- readTVar st.isPending
  case Map.lookup gid m of
    Nothing -> pure []
    Just msgs -> do
      writeTVar st.isPending (Map.delete gid m)
      pure msgs.piMessages

-- | One classifier round: build the prompt, ask the profile, parse
-- the verdict.  On success the full input rides along with the
-- verdict in an @intent: verdict@ log line, so production rounds can
-- be replayed offline against a fixture (see @eval/README.md@ and
-- the @max-intent-eval@ executable).
classifyOnce ::
  (LLM :> es, Log :> es) =>
  Maybe Int64 -> -- group under classification (usage attribution; Nothing in the eval harness)
  Text -> -- LLM profile
  Text -> -- persona
  [Text] -> -- context lines, chronological
  [Text] -> -- new (unclassified) lines
  Eff es (Maybe IntentVerdict)
classifyOnce mGid profile persona ctxLines newLines = do
  let userBody =
        T.intercalate "\n" $
          ["[context]"]
            <> (if null ctxLines then ["(无)"] else ctxLines)
            <> ["", "[new messages]"]
            <> (if null newLines then ["(见上下文末尾)"] else newLines)
  r <- chat (ChatCtx "intent" mGid Nothing Nothing Nothing Nothing) profile [MsgSystem (classifierSystem persona), MsgUser userBody] []
  case r of
    Left err -> do
      logAttention "intent: classify failed" $ object ["error" .= err]
      pure Nothing
    Right (ToolCallsResp {}) -> do
      logAttention "intent: unexpected tool_calls" $ object []
      pure Nothing
    Right (ContentResp txt) -> case parseVerdict txt of
      Nothing -> do
        logAttention "intent: unparseable verdict" $ object ["raw" .= T.take 200 txt]
        pure Nothing
      Just v -> do
        logInfo "intent: verdict" $
          object
            [ "context" .= ctxLines,
              "new" .= newLines,
              "trigger" .= v.ivTrigger,
              "kind" .= kindText v.ivKind,
              "reason" .= v.ivReason
            ]
        pure (Just v)

--------------------------------------------------------------------------------
-- Classifier prompt + verdict.

classifierSystem :: Text -> Text
classifierSystem persona =
  T.intercalate
    "\n"
    [ "你是多人群聊 agent「Max」的触发判定器。Max 的人设：",
      T.take 500 persona,
      "",
      "给你一段群聊上下文和几条新消息（都没有 @Max 也没有引用它）。判断 Max 是否应该主动接话。",
      "",
      "应该接话（trigger=true）：",
      "1. 有人在叫 Max 或找它帮忙，只是没打 @ —— 如\"max帮我看看\"\"机器人查一下\"\"Max你觉得呢\"。",
      "2. Max 刚参与的对话有了后续：有人在回应、追问或反驳 Max 刚说的话。",
      "3. 正在讨论 Max 感兴趣的话题，且它能给出具体有用的东西（答案、纠错、关键信息）。",
      "",
      "不该接话（trigger=false）：",
      "- 成员之间的日常闲聊，与 Max 无关；",
      "- 只是顺带提到/议论 Max，不是在跟它说话；",
      "- 其他机器人发的机械消息（播报、复读、签到等）；",
      "- 第 3 类要格外克制：只能附和、发感想、抖机灵的不算；上下文里 Max 已经插过话的话题，别人没接它的茬就不要再插；",
      "- 拿不准的一律 false —— 插错话比沉默尴尬得多，偶尔插话才有惊喜，频繁插话只会烦人。",
      "",
      "只输出一行 JSON，不要其他内容：",
      "{\"trigger\": true/false, \"kind\": \"called\"|\"followup\"|\"topic\", \"reason\": \"不超过20字\"}",
      "kind 对应上面三类：called=有人在叫它/找它帮忙；followup=它参与的对话的后续；topic=感兴趣的话题。"
    ]

-- | Which of the three trigger categories fired.  Throttling depends
-- on it: only 'KindTopic' respects the cooldown.
data IntentKind = KindCalled | KindFollowup | KindTopic
  deriving stock (Show, Eq)

kindText :: IntentKind -> Text
kindText = \case
  KindCalled -> "called"
  KindFollowup -> "followup"
  KindTopic -> "topic"

data IntentVerdict = IntentVerdict
  { ivTrigger :: !Bool,
    -- | Defaults to 'KindTopic' (the most-throttled kind) when the
    -- model omits or mangles the field.
    ivKind :: !IntentKind,
    ivReason :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

instance FromJSON IntentVerdict where
  parseJSON = withObject "verdict" $ \o -> do
    trig <- o .: "trigger"
    mKind <- o .:? "kind"
    reason <- o .:? "reason"
    let kind = case mKind :: Maybe Text of
          Just "called" -> KindCalled
          Just "followup" -> KindFollowup
          _ -> KindTopic
    pure (IntentVerdict trig kind reason)

-- | Parse the classifier's reply.  Tolerates markdown fences and
-- prose around the JSON object — everything outside the outermost
-- @{..}@ is ignored.
parseVerdict :: Text -> Maybe IntentVerdict
parseVerdict txt = do
  obj <- extractObject txt
  either (const Nothing) Just (eitherDecodeStrict' (TE.encodeUtf8 obj))

-- | The substring from the first @{@ through the matching last @}@.
extractObject :: Text -> Maybe Text
extractObject t =
  let afterOpen = T.dropWhile (/= '{') t
      beforeClose = T.dropWhileEnd (/= '}') afterOpen
   in if T.null beforeClose then Nothing else Just beforeClose
