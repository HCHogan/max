module Max.Handler.QQ
  ( handleEvents,
    IngestOutcome (..),
    ingestAllowsDownstream,
    recordAs,
  )
where

import Control.Concurrent.STM
  ( TQueue,
    TVar,
    atomically,
    readTQueue,
  )
import Control.Monad (forM_, when)
import Data.Aeson (ToJSON (toJSON), Value)
import Data.Char (isSpace)
import Data.Either (rights)
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Maybe (maybeToList)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, addUTCTime, getCurrentTime)
import Data.Time qualified as Time
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Concurrent.Async (Concurrent)
import Effectful.Log
  ( Log,
    logAttention,
    logAttention_,
    logInfo,
    logTrace,
    object,
    (.=),
  )
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Command.Parser (parseCommand)
import Max.Command.Types (Command (..))
import Max.DB.QQBackfill
  ( QQBackfillEndpoint (..),
    QQBackfillResult (..),
    finishQQBackfillRun,
    listQQBackfillEndpoints,
    startQQBackfillRun,
  )
import Max.Effects.Agent (Agent)
import Max.Effects.Blob (Blob)
import Max.Effects.Outbound (Outbound)
import Max.Effects.PlatformAccount
  ( FriendRequestDecision (..),
    PlatformAccount,
    respondToFriendRequest,
  )
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Env (BotEnv (..))
import Max.EpisodeScheduler (bumpEpisode)
import Max.FetchQueue (FetchSignal, notifyFetch)
import Max.Handler (onPoke)
import Max.IR.Digest (digest)
import Max.Intent (IntentState)
import Max.MessageKind (MessageKind (..), renderMessageKind)
import Max.ModelCatalog (ModelCatalog)
import Max.Platform.Envelope
  ( InboundEnvelope (..),
    IngestClass (Backfill),
  )
import Max.Platform.Failure
  ( PlatformFailure (..),
    renderPlatformFailure,
  )
import Max.Platform.Ingress (Ingress, queueIngest)
import Max.Platform.QQ
  ( ensureQQEndpoint,
    ensureQQEndpointFor,
    qqEnvelope,
    qqIngestBody,
    qqNoticeEnvelopes,
  )
import Max.Platform.QQHistory
  ( QQHistoryPage (..),
    qqGenerationIsCurrent,
    readQQHistoryPage,
  )
import Max.Platform.Store.Endpoint
  ( RegisteredEndpoint (compatibilityConversationId, endpointId),
  )
import Max.Platform.Store.Ingest
  ( IngestOptions (..),
    IngestResult (..),
    NewIngest (canonicalBody, canonicalMessageId),
    defaultIngestOptions,
    ingestEnvelope,
  )
import Max.Platform.Types (CanonicalMessageId)
import Max.Util (readIntegral, trySync, tshow)
import OneBot.Event
  ( Event (..),
    GroupMessage (..),
    HistoricalMessage (hmMessage, hmOccurredAt, hmRaw),
    HistoryParseFailureSummary (..),
    MessageNotice (mnGroupId, mnSelfId),
    selectHistoryBefore,
    summarizeHistoryParseFailures,
  )
import OneBot.Segment (Segment (..), renderPlainText)
import OneBot.Server (ClientSlot)
import OneBot.Types
  ( GroupId (..),
    MessageId (..),
    UserId (..),
    isPrivateChat,
  )

data IngestOutcome
  = IngestDurable !CanonicalMessageId
  | IngestDuplicate
  | IngestFailed !T.Text
  deriving stock (Show, Eq)

ingestAllowsDownstream :: IngestOutcome -> Bool
ingestAllowsDownstream IngestDurable {} = True
ingestAllowsDownstream IngestDuplicate = False
ingestAllowsDownstream IngestFailed {} = False

-- | Classify stored messages. Non-empty !btw/!feedback bodies become chat
-- with the command verb removed; other commands remain command records.
-- Only the prompt-facing IR changes; raw QQ provenance is retained.
recordAs :: GroupMessage -> (MessageKind, Maybe T.Text)
recordAs gm =
  case parseCommand stripped of
    Right Nothing -> (KindChat, Nothing)
    Right (Just cmd)
      | Just note <- conversational cmd,
        not (T.null (T.strip note)) ->
          (KindChat, Just (renderPlainText (stripVerb gm.message)))
    _ -> (KindCommand, Nothing)
  where
    stripped = T.strip (stripMentions gm.selfId (T.strip (renderPlainText gm.message)))
    conversational = \case
      Btw note -> Just note
      Feedback note -> Just note
      _ -> Nothing

-- | Drop the leading @!verb@ from the first text segment carrying one,
-- leaving everything before it — notably the @-mention — in place, so
-- the line reads like any other message to the bot.
stripVerb :: [Segment] -> [Segment]
stripVerb [] = []
stripVerb (SegText t : rest)
  | Just body <- T.stripPrefix "!" (T.stripStart t) =
      SegText (T.stripStart (T.dropWhile (not . isSpace) body)) : rest
stripVerb (s : rest) = s : stripVerb rest

-- | Ingest QQ events, backfill on reconnect, and route non-message interactions.
handleEvents ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    PlatformAccount :> es,
    Outbound :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  TQueue Event ->
  -- | Process-local media queues and discovery wakeup.
  FetchSignal ->
  Maybe IntentState -> -- proactive-trigger buffers ('Nothing' = feature off)
  TVar ClientSlot ->
  Eff es ()
handleEvents q fetchSig mIntent clientRef = loop
  where
    loop = do
      ev <- liftIO (atomically (readTQueue q))
      env <- ask @BotEnv
      handle (mIntent >>= \intentState -> intentState <$ env.beIntent) ev
      loop

    handle activeIntent ev =
      case ev of
        EvConnectionReady generation connectedAt ->
          trySync (recoverQQHistory clientRef generation connectedAt fetchSig) >>= \case
            Right () -> pure ()
            Left e ->
              logAttention "QQ history backfill crashed; live ingress will continue" $
                object
                  [ "connection_generation" .= generation,
                    "error" .= T.pack (show e),
                    "coverage" .= ("best-effort-messages-only" :: T.Text)
                  ]
        EvHeartbeat -> pure ()
        EvLifecycle sub ->
          logInfo "lifecycle" $ object ["sub_type" .= sub]
        EvRaw _ ->
          -- Unknown OneBot events may contain an entire user-authored payload.
          -- Keep the diagnostic marker, but leave the durable raw copy to the
          -- canonical ingest paths that understand the event shape.
          logTrace "unhandled event" $ object []
        EvGroupMessage source raw gm -> do
          -- Move the quiet boundary before the row becomes visible to the
          -- historian's DB scan.  Otherwise a due scan could race persistence
          -- and fold the just-arrived live-tail message.
          env :: BotEnv <- ask
          for_ env.beEpisodeScheduler $ \scheduler -> liftIO (bumpEpisode scheduler gm.groupId)
          persisted <- persist env.beIngress source raw gm
          case persisted of
            IngestDurable _ -> pure ()
            IngestDuplicate -> do
              let MessageId messageId = gm.messageId
              logTrace "ingest: duplicate source event ignored" $
                object ["source" .= source, "message_id" .= messageId]
            IngestFailed {} -> do
              let GroupId groupId = gm.groupId
                  MessageId messageId = gm.messageId
              logAttention "ingest: downstream work suppressed because ledger insert failed" $
                object
                  [ "group_id" .= groupId,
                    "message_id" .= messageId,
                    "state" .= ("not-durable" :: T.Text)
                  ]
        EvMessageNotice raw notice -> do
          endpoint <- ensureQQEndpointFor notice.mnSelfId notice.mnGroupId
          received <- liftIO getCurrentTime
          forM_ (qqNoticeEnvelopes endpoint received raw notice) $ \envelope -> do
            ingestEnvelope
              defaultIngestOptions
                { createDispatch = False,
                  createMirrorDeliveries = True,
                  transcriptKind = renderMessageKind KindSystem
                }
              envelope
              >>= \case
                Ingested fresh ->
                  logInfo "QQ meta-event ingested" $
                    object
                      [ "canonical_message_id" .= fresh.canonicalMessageId,
                        "content" .= digest fresh.canonicalBody
                      ]
                AlreadyIngested {} -> pure ()
                DeliveryEcho {} -> pure ()
                EchoUnmatched -> pure ()
        EvPoke pk -> onPoke activeIntent pk
        -- QQ private command replies require friendship; accept incoming requests.
        EvFriendRequest flag (UserId uidRaw) -> do
          logInfo "friend request: auto-approving" $ object ["user_id" .= uidRaw]
          respondToFriendRequest flag AcceptFriend >>= either (logAttention_ . renderPlatformFailure) pure

-- | Classify command syntax before persistence, including malformed commands.
-- Reply-to-bot lookup and other dispatch decisions happen later.
persist :: (Log :> es, WithConnection :> es, IOE :> es) => Ingress -> T.Text -> Value -> GroupMessage -> Eff es IngestOutcome
persist ingress source raw gm =
  trySync persistOne >>= \case
    Right outcome -> pure outcome
    Left e -> do
      let message = T.pack (show e)
      logAttention "db insert failed" $
        object ["error" .= message]
      pure (IngestFailed message)
  where
    persistOne
      | source == "qq" = do
          endpoint <- ensureQQEndpoint gm
          received <- liftIO getCurrentTime
          let (kind, rewritten) = recordAs gm
              contentSegments = case (kind, rewritten) of
                (KindChat, Just _) -> stripVerb gm.message
                _ -> gm.message
              options =
                defaultIngestOptions
                  { transcriptKind = renderMessageKind kind,
                    qqProvenanceSegments = Just (toJSON gm.message)
                  }
              envelope = (qqEnvelope endpoint received raw gm) {content = qqIngestBody contentSegments}
          ingestEnvelope options envelope >>= \case
            Ingested fresh -> do
              logInfo "QQ event ingested" $
                object
                  [ "canonical_message_id" .= fresh.canonicalMessageId,
                    "content" .= digest fresh.canonicalBody
                  ]
              liftIO (queueIngest ingress (Ingested fresh))
              pure (IngestDurable fresh.canonicalMessageId)
            AlreadyIngested _ -> pure IngestDuplicate
            DeliveryEcho _ -> pure IngestDuplicate
            EchoUnmatched -> pure IngestDuplicate
      | otherwise = error ("non-QQ event entered the OneBot ingress queue: " <> T.unpack source)

-- QQ reverse WS is not replayable, but NapCat exposes finite message-history
-- actions.  A connection-ready event sits ahead of every live frame in the
-- FIFO queue, so doing this synchronously preserves old-to-new ledger order
-- while the websocket read loop remains free to answer the calls below.
qqBackfillEndpointLimit :: Int
qqBackfillEndpointLimit = 16

qqBackfillPageCount :: Int
qqBackfillPageCount = 100

qqBackfillCallTimeoutMs :: Int
qqBackfillCallTimeoutMs = 2500

qqBackfillOverallSeconds :: NominalDiffTime
qqBackfillOverallSeconds = 20

data QQBackfillCounts = QQBackfillCounts
  { qbcInserted :: !Int,
    qbcDuplicate :: !Int
  }

emptyQQBackfillCounts :: QQBackfillCounts
emptyQQBackfillCounts = QQBackfillCounts 0 0

recoverQQHistory ::
  (Log :> es, WithConnection :> es, IOE :> es) =>
  TVar ClientSlot ->
  Int ->
  Time.UTCTime ->
  FetchSignal ->
  Eff es ()
recoverQQHistory clientRef generation connectedAt fetchSig = do
  startedAt <- liftIO getCurrentTime
  let deadline = addUTCTime qqBackfillOverallSeconds startedAt
  candidates <- listQQBackfillEndpoints (qqBackfillEndpointLimit + 1)
  let endpoints = take qqBackfillEndpointLimit candidates
      capped = length candidates > qqBackfillEndpointLimit
  logInfo "QQ history backfill started" $
    object
      [ "connection_generation" .= generation,
        "endpoint_count" .= length endpoints,
        "endpoint_limit_reached" .= capped,
        "page_count" .= qqBackfillPageCount,
        "coverage" .= ("best-effort-messages-only" :: T.Text)
      ]
  inserted <- recoverEndpoints deadline endpoints 0
  when (inserted > 0) (liftIO (notifyFetch fetchSig))
  current <- liftIO (qqGenerationIsCurrent clientRef generation)
  logInfo "QQ history backfill finished" $
    object
      [ "connection_generation" .= generation,
        "inserted_count" .= inserted,
        "generation_still_current" .= current,
        "endpoint_limit_reached" .= capped,
        "coverage" .= ("best-effort-messages-only" :: T.Text)
      ]
  where
    recoverEndpoints _ [] inserted = pure inserted
    recoverEndpoints deadline (endpoint : rest) inserted = do
      now <- liftIO getCurrentTime
      current <- liftIO (qqGenerationIsCurrent clientRef generation)
      if now >= deadline || not current
        then do
          logAttention "QQ history backfill stopped before all known endpoints" $
            object
              [ "connection_generation" .= generation,
                "remaining_endpoint_count" .= length (endpoint : rest),
                "reason" .= if current then ("overall-deadline" :: T.Text) else "connection-generation-changed"
              ]
          pure inserted
        else do
          added <- recoverQQEndpoint clientRef generation connectedAt deadline endpoint
          recoverEndpoints deadline rest (inserted + added)

recoverQQEndpoint ::
  (Log :> es, WithConnection :> es, IOE :> es) =>
  TVar ClientSlot ->
  Int ->
  Time.UTCTime ->
  Time.UTCTime ->
  QQBackfillEndpoint ->
  Eff es Int
recoverQQEndpoint clientRef generation connectedAt deadline endpoint = do
  runId <- startQQBackfillRun generation endpoint connectedAt qqBackfillPageCount
  case readIntegral endpoint.qbeNativeAccountId :: Maybe Int64 of
    Nothing -> finishSkipped runId "invalid-account-id" "QQ native account id is not an integer"
    Just selfRaw ->
      let self = UserId selfRaw
          group = GroupId endpoint.qbeEndpoint.compatibilityConversationId
       in if invalidQQGroup group
            then finishSkipped runId "invalid-conversation-id" "QQ compatibility conversation id is not a group or friend"
            else do
              let anchor = nonBlankSequence endpoint.qbeAnchorMessageSeq
                  requests =
                    ("latest", Nothing)
                      : [("anchor", Just sequenceNumber) | sequenceNumber <- maybeToList anchor]
              (responses, requestErrors) <- callHistoryPages clientRef generation self group deadline requests
              let pages = rights responses
                  succeededPages = length (filter (.qhpSucceeded) pages)
                  fetched = sum (length . (.qhpMessages) <$> pages)
                  parseFailures = sum ((.qhpParseFailures) <$> pages)
                  parseFailureDetails = concatMap (.qhpParseFailureDetails) pages
                  parseFailureSummaries = summarizeHistoryParseFailures 3 parseFailureDetails
                  pageErrors = concatMap (.qhpErrors) pages
                  (selected, afterCutoff) = selectHistoryBefore connectedAt (concatMap (.qhpMessages) pages)
              (counts, ingestErrors) <- ingestHistoricalMessages clientRef generation deadline endpoint selected
              current <- liftIO (qqGenerationIsCurrent clientRef generation)
              finishedAt <- liftIO getCurrentTime
              let deadlineExpired = finishedAt >= deadline
                  errors =
                    requestErrors
                      <> pageErrors
                      <> [renderHistoryParseFailureSummary parseFailureSummaries | not (null parseFailureSummaries)]
                      <> ingestErrors
                      <> ["overall deadline reached" | deadlineExpired && null ingestErrors]
                  complete = succeededPages > 0 && null errors && parseFailures == 0 && current && not deadlineExpired
                  status
                    | succeededPages == 0 = "failed"
                    | complete = "succeeded"
                    | otherwise = "partial"
                  reason
                    | not current = "connection-generation-changed"
                    | deadlineExpired = "overall-deadline"
                    | succeededPages == 0 = "all-history-requests-failed"
                    | not (null ingestErrors) = "ingest-failures"
                    | parseFailures > 0 = "malformed-history-rows"
                    | not (null errors) = "some-history-requests-failed"
                    | otherwise = "bounded-window-complete"
                  result =
                    QQBackfillResult
                      { qbrStatus = status,
                        qbrFetchedCount = fetched,
                        qbrInsertedCount = counts.qbcInserted,
                        qbrDuplicateCount = counts.qbcDuplicate,
                        qbrSkippedAfterCutoff = afterCutoff,
                        qbrParseFailureCount = parseFailures,
                        qbrStopReason = reason,
                        qbrError = nonEmptyError errors
                      }
              finishQQBackfillRun runId result
              logInfo "QQ history endpoint backfill finished" $
                object
                  [ "connection_generation" .= generation,
                    "endpoint_id" .= endpoint.qbeEndpoint.endpointId,
                    "status" .= status,
                    "fetched_count" .= fetched,
                    "selected_count" .= length selected,
                    "inserted_count" .= counts.qbcInserted,
                    "duplicate_count" .= counts.qbcDuplicate,
                    "skipped_after_cutoff" .= afterCutoff,
                    "parse_failure_count" .= parseFailures,
                    "parse_failure_reasons" .= (historyParseFailureSummaryValue <$> parseFailureSummaries),
                    "stop_reason" .= reason,
                    "coverage" .= ("best-effort-messages-only" :: T.Text)
                  ]
              pure counts.qbcInserted
  where
    finishSkipped runId reason err = do
      finishQQBackfillRun
        runId
        QQBackfillResult
          { qbrStatus = "skipped",
            qbrFetchedCount = 0,
            qbrInsertedCount = 0,
            qbrDuplicateCount = 0,
            qbrSkippedAfterCutoff = 0,
            qbrParseFailureCount = 0,
            qbrStopReason = reason,
            qbrError = Just err
          }
      logAttention "QQ history endpoint backfill skipped" $
        object
          [ "connection_generation" .= generation,
            "endpoint_id" .= endpoint.qbeEndpoint.endpointId,
            "reason" .= reason
          ]
      pure 0

    invalidQQGroup gid@(GroupId raw) = raw == 0 || (raw < 0 && not (isPrivateChat gid))

    nonBlankSequence Nothing = Nothing
    nonBlankSequence (Just raw) =
      let value = T.strip raw
       in if T.null value || value == "0" then Nothing else Just value

callHistoryPages ::
  (IOE :> es) =>
  TVar ClientSlot ->
  Int ->
  UserId ->
  GroupId ->
  Time.UTCTime ->
  [(T.Text, Maybe T.Text)] ->
  Eff es ([Either PlatformFailure QQHistoryPage], [T.Text])
callHistoryPages clientRef generation self group deadline = go [] []
  where
    go responses errors [] = pure (reverse responses, reverse errors)
    go responses errors ((label, anchor) : rest) = do
      now <- liftIO getCurrentTime
      if now >= deadline
        then pure (reverse responses, reverse ((label <> ": overall deadline") : errors))
        else do
          response <- liftIO (readQQHistoryPage clientRef generation self group anchor qqBackfillPageCount qqBackfillCallTimeoutMs)
          let errors' = case response of
                Left err -> (label <> ": " <> renderPlatformFailure err) : errors
                Right _ -> errors
          case response of
            Left PlatformGenerationChanged -> pure (reverse (response : responses), reverse errors')
            _ -> go (response : responses) errors' rest

historyParseFailureSummaryValue :: HistoryParseFailureSummary -> Value
historyParseFailureSummaryValue summary =
  object
    [ "reason" .= summary.hpfsReason,
      "count" .= summary.hpfsCount,
      "sample_message_id" .= summary.hpfsSampleMessageId,
      "sample_fields" .= summary.hpfsSampleFields
    ]

renderHistoryParseFailureSummary :: [HistoryParseFailureSummary] -> T.Text
renderHistoryParseFailureSummary summaries =
  "malformed history rows: "
    <> T.intercalate
      ", "
      [ summary.hpfsReason <> "=" <> tshow summary.hpfsCount
      | summary <- summaries
      ]

ingestHistoricalMessages ::
  (WithConnection :> es, IOE :> es) =>
  TVar ClientSlot ->
  Int ->
  Time.UTCTime ->
  QQBackfillEndpoint ->
  [HistoricalMessage] ->
  Eff es (QQBackfillCounts, [T.Text])
ingestHistoricalMessages clientRef generation deadline endpoint = go emptyQQBackfillCounts []
  where
    go counts errors [] = pure (counts, reverse errors)
    go counts errors (historical : rest) = do
      now <- liftIO getCurrentTime
      current <- liftIO (qqGenerationIsCurrent clientRef generation)
      if now >= deadline || not current
        then
          pure
            ( counts,
              reverse
                ( (if current then "overall deadline during ingest" else "connection generation changed during ingest")
                    : errors
                )
            )
        else
          trySync (persistHistorical endpoint.qbeEndpoint historical) >>= \case
            Left e ->
              go counts (T.take 2000 (T.pack (show e)) : errors) rest
            Right (Ingested _) ->
              go counts {qbcInserted = counts.qbcInserted + 1} errors rest
            Right (AlreadyIngested {}) ->
              go counts {qbcDuplicate = counts.qbcDuplicate + 1} errors rest
            Right (DeliveryEcho {}) ->
              go counts {qbcDuplicate = counts.qbcDuplicate + 1} errors rest
            Right EchoUnmatched ->
              go counts {qbcDuplicate = counts.qbcDuplicate + 1} errors rest

persistHistorical ::
  (WithConnection :> es, IOE :> es) =>
  RegisteredEndpoint ->
  HistoricalMessage ->
  Eff es IngestResult
persistHistorical endpoint historical = do
  received <- liftIO getCurrentTime
  let gm = historical.hmMessage
      (kind, rewritten) = recordAs gm
      contentSegments = case (kind, rewritten) of
        (KindChat, Just _) -> stripVerb gm.message
        _ -> gm.message
      options =
        defaultIngestOptions
          { createDispatch = False,
            createMirrorDeliveries = False,
            transcriptKind = renderMessageKind kind,
            qqProvenanceSegments = Just (toJSON gm.message)
          }
      envelope =
        (qqEnvelope endpoint received historical.hmRaw gm)
          { ingestClass = Backfill,
            occurredAt = historical.hmOccurredAt,
            content = qqIngestBody contentSegments
          }
  ingestEnvelope options envelope

nonEmptyError :: [T.Text] -> Maybe T.Text
nonEmptyError [] = Nothing
nonEmptyError errors = Just (T.take 4000 (T.intercalate "; " errors))

-- | QQ-ingress only: this path still holds the raw OneBot segments, where the
-- bot's compatibility id and its native id are the same number.  Canonical
-- dispatch uses 'dispatchTextWithoutSelf' instead.
stripMentions :: UserId -> T.Text -> T.Text
stripMentions (UserId u) t =
  foldr
    (\m acc -> T.replace m "" acc)
    t
    ["[@#" <> uid <> "] ", "[@#" <> uid <> "]", "@" <> uid]
  where
    uid = T.pack (show u)
