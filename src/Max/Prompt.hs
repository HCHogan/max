module Max.Prompt
  ( -- * Pipeline
    buildContext,
    buildContextWithLimits,
    buildContextWithReadMode,
    buildContextWithReadModeForOutput,
    ContextReadMode (..),
    TriggerOrigin (..),

    -- * Building blocks (exposed for tests)
    PromptInputs (..),
    ContextCandidates (..),
    SelectedContext (..),
    PromptImage (..),
    ContextCompartment (..),
    CompartmentTier (..),
    ContextSnapshot (..),
    csInputs,
    ContextPlan (..),
    cpInputs,
    collectContext,
    collectContextPreview,
    planContext,
    materializeTieredHistory,
    HistoryTokenWatermarks (..),
    applyBaseCompartmentTiers,
    renderContextPlan,
    renderContext,
    contextRoster,
    applyStickerCaptions,
    applyVideoCaptions,
    tagImageMarkers,

    -- * Shared line rendering (used by "Max.Intent" / "Max.Handler")
    renderHistoryLine,
    renderCurrentLine,

    -- * Forward markers (shared with "Max.Tools")
    tagMediaMarkers,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (unless, when)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Either (partitionEithers)
import Data.Function (on)
import Data.Int (Int64)
import Data.List (find, groupBy, minimumBy, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone, UTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (In (..), Only (..))
import Effectful
import Effectful.Exception (IOException, try)
import Effectful.Log (Log, logAttention, logInfo, object, (.=))
import Effectful.PostgreSQL (WithConnection, query)
import Max.Context
  ( ContextBudget (..),
    ContextDecision (..),
    ContextTrace (..),
    contextBudget,
    estimateMessagesTokens,
    estimateTextTokens,
  )
import Max.Context.Policy
  ( ContextCostModel (..),
    PolicyDrop (..),
    applyBaseCompartmentTiers,
    compartmentTierText,
    selectContextTo,
    selectedCompartmentSummary,
  )
import Max.Context.Types
  ( CompartmentTier (..),
    ContextCandidates (..),
    ContextCompartment (..),
    ContextPlan (..),
    ContextReadMode (..),
    ContextSnapshot (..),
    HistoryTokenWatermarks (..),
    PromptImage (..),
    PromptInputs (..),
    SelectedContext (..),
    TriggerOrigin (..),
    cpInputs,
    csInputs,
  )
import Max.ContextMaterialization
  ( ContextMaterialization (..),
    MaterializationDraft (..),
    MaterializedCompartment (..),
    loadContextMaterialization,
    publishContextMaterialization,
  )
import Max.ContextTraceStore (recordContextPlanTrace)
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.Files (FileRecord (..))
import Max.DB.Files qualified as DBFiles
import Max.DB.History
  ( HistoryItem (..),
    HistoryPage (..),
    LedgerItem (..),
    MessageCursor (..),
    bestName,
    fetchForwardChildrenInScope,
    fetchMessageInScope,
    fetchMessagesByIdsInScope,
    fetchNewestPromptPageBefore,
  )
import Max.Dispatch (DispatchMessage (..), dispatchText, dispatchTextWithoutSelf)
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.Effects.LLM (ChatMessage (..), ContentBlock (..))
import Max.EpisodeStore (ActiveCompartment (..), CompartmentId (..), SourceRange (..), episodeHandleText, listActiveCompartments)
import Max.ImagePrep (prepareImageForLLM)
import Max.Images (downloadableImageCount, downloadableVideoCount)
import Max.IR (Body (..), Node (..), Phase (Canonical))
import Max.MemoryStore (MemoryId (..), MemoryItem (..), MemoryVersion (..), groupMemoryNamespace, listRecentMemories, userMemoryNamespace)
import Max.ModelCatalog (ContextLimits, defaultContextLimits)
import Max.Platform.Types (AdvertisedCaps (..), qqAdvertisedCaps)
import Max.Prompt.System (systemPrompt)
import Max.Session (Session (..))
import Max.Time (fmtDate, fmtDurationSec, fmtEnvStamp, fmtHM)
import Max.Util (trySync)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)

-- Group-chat attention gets noisier faster than model windows grow.  These
-- ceilings keep the protected verbatim tail roomy but stable when a future
-- profile advertises 256K+ input; older context remains available through
-- tiered compartments and unified recall.
rawTailLowCeiling :: Int
rawTailLowCeiling = 16384

rawTailHighCeiling :: Int
rawTailHighCeiling = 32768

historyTokenWatermarks :: ContextLimits -> Bool -> HistoryTokenWatermarks
historyTokenWatermarks limits multimodal' =
  HistoryTokenWatermarks
    { htwLow = min rawTailLowCeiling (max 512 (promptLimit `div` 5)),
      htwHigh = min rawTailHighCeiling (max 1024 (promptLimit * 2 `div` 5))
    }
  where
    promptLimit = (contextBudget limits multimodal').cbPromptTokenLimit

-- Nothing volatile below this point.  The environment block
-- (current time, per-turn roster) and the memory block used to
-- sit here at the end; they now live in the user message, after
-- the transcript.  A prefix cache stops at the first byte that
-- changed, so a clock in the system prompt capped every provider
-- cache at "persona + format guide" no matter how stable the
-- conversation below it was.

-- | Build the chat context for one @bot trigger.  Runs the DB
-- fetches, then hands off to the pure 'renderContext'.
--
-- When @multimodal@ is 'True', also looks up the local bytes of
-- images on the trigger AND on context messages (reply target, pins,
-- recent history) and embeds them as inline data URLs so the final
-- @user@ message becomes 'MsgUserBlocks' instead of 'MsgUser'.
-- Falls back gracefully when the image worker hasn't caught up yet —
-- those images stay as @[image]@ markers.
buildContext ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- default persona (used when session has no override)
  Bool -> -- multimodal: load + attach inline images
  Bool -> -- history as user/assistant turns (see 'PromptInputs.historyTurns')
  TriggerOrigin -> -- what woke the bot (see 'PromptInputs.origin')
  TimeZone -> -- display timezone for rendered timestamps
  [Text] -> -- pre-rendered 群信息 lines (see 'PromptInputs.groupBrief')
  [(Text, Text)] -> -- skill index for this group (see 'PromptInputs.skills')
  Set Int64 -> -- triggers another turn is already answering (see 'PromptInputs.inFlight')
  Session ->
  DispatchMessage ->
  Eff es [ChatMessage]
buildContext = buildContextWithLimits defaultContextLimits

-- | Production entry point with limits taken from the selected model profile.
buildContextWithLimits ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ContextLimits ->
  Text ->
  Bool ->
  Bool ->
  TriggerOrigin ->
  TimeZone ->
  [Text] ->
  [(Text, Text)] ->
  Set Int64 ->
  Session ->
  DispatchMessage ->
  Eff es [ChatMessage]
buildContextWithLimits limits = buildContextWithReadMode limits TieredContext

buildContextWithReadMode ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ContextLimits ->
  ContextReadMode ->
  Text ->
  Bool ->
  Bool ->
  TriggerOrigin ->
  TimeZone ->
  [Text] ->
  [(Text, Text)] ->
  Set Int64 ->
  Session ->
  DispatchMessage ->
  Eff es [ChatMessage]
buildContextWithReadMode limits readMode defaultPersona multimodal' historyTurns' origin' tz' brief skills' inFlight' s gm = do
  buildContextWithReadModeForOutput
    limits
    readMode
    qqAdvertisedCaps
    defaultPersona
    multimodal'
    historyTurns'
    origin'
    tz'
    brief
    skills'
    inFlight'
    s
    gm

-- | Production variant whose action grammar is constrained by the enabled
-- conversation endpoints.  The compatibility wrapper above keeps pure/legacy
-- fixtures stable, but live dispatches must call this function with the
-- endpoint-owned intersection from 'Max.Platform.Store'.
buildContextWithReadModeForOutput ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ContextLimits ->
  ContextReadMode ->
  AdvertisedCaps ->
  Text ->
  Bool ->
  Bool ->
  TriggerOrigin ->
  TimeZone ->
  [Text] ->
  [(Text, Text)] ->
  Set Int64 ->
  Session ->
  DispatchMessage ->
  Eff es [ChatMessage]
buildContextWithReadModeForOutput limits readMode outputCaps defaultPersona multimodal' historyTurns' origin' tz' brief skills' inFlight' s gm = do
  let historyWatermarks = historyTokenWatermarks limits multimodal'
  snapshot <-
    collectContextWithWatermarks
      PublishMaterialization
      readMode
      (Just historyWatermarks)
      outputCaps
      defaultPersona
      multimodal'
      historyTurns'
      origin'
      tz'
      brief
      skills'
      inFlight'
      s
      gm
  let plan = planContext limits snapshot
      MessageId triggerMessageId = gm.messageId
      scope = conversationScopeFor gm.groupId
  traceStored <-
    trySync $
      recordContextPlanTrace
        scope
        triggerMessageId
        (contextReadModeText readMode)
        plan.cpPolicyVersion
        plan.cpMaterializationVersion
        plan.cpMaterializationReason
        plan.cpBudget
        plan.cpEstimatedPromptTokens
        plan.cpWithinBudget
        plan.cpTrace
  case traceStored of
    Left err ->
      logAttention "context: failed to persist planning trace" $
        object ["group_id" .= (let GroupId groupId = gm.groupId in groupId), "error" .= T.pack (show err)]
    Right () -> pure ()
  unless plan.cpWithinBudget $
    logAttention "context plan exceeds model input budget" $
      object
        [ "estimated_prompt_tokens" .= plan.cpEstimatedPromptTokens,
          "prompt_token_limit" .= plan.cpBudget.cbPromptTokenLimit,
          "policy_version" .= plan.cpPolicyVersion
        ]
  pure (renderContextPlan plan)

contextReadModeText :: ContextReadMode -> Text
contextReadModeText = \case
  TieredContext -> "tiered"
  RawLedgerEmergency -> "raw_emergency"

-- | Effectful I/O only: fetch and enrich a complete snapshot.  Selection and
-- token pressure happen later in the pure policy step.
collectContext ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  Bool ->
  Bool ->
  TriggerOrigin ->
  TimeZone ->
  [Text] ->
  [(Text, Text)] ->
  Set Int64 ->
  Session ->
  DispatchMessage ->
  Eff es ContextSnapshot
collectContext = collectContextWithWatermarks PublishMaterialization TieredContext Nothing qqAdvertisedCaps

-- | Read-only collection for admin previews and replay evaluation. It never
-- publishes a materialization revision or a diagnostic row; callers may pass
-- the returned snapshot to 'planContext' and render it independently.
collectContextPreview ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text ->
  Bool ->
  Bool ->
  TriggerOrigin ->
  TimeZone ->
  [Text] ->
  [(Text, Text)] ->
  Set Int64 ->
  Session ->
  DispatchMessage ->
  Eff es ContextSnapshot
collectContextPreview = collectContextWithWatermarks ReadOnlyPreview TieredContext Nothing qqAdvertisedCaps

data ContextMutationMode
  = PublishMaterialization
  | ReadOnlyPreview
  deriving stock (Show, Eq)

collectContextWithWatermarks ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ContextMutationMode ->
  ContextReadMode ->
  Maybe HistoryTokenWatermarks ->
  AdvertisedCaps ->
  Text ->
  Bool ->
  Bool ->
  TriggerOrigin ->
  TimeZone ->
  [Text] ->
  [(Text, Text)] ->
  Set Int64 ->
  Session ->
  DispatchMessage ->
  Eff es ContextSnapshot
collectContextWithWatermarks mutationMode readMode materializationWatermarks outputCaps defaultPersona multimodal' historyTurns' origin' tz' brief skills' inFlight' s gm = do
  let GroupId gid = gm.groupId
      MessageId mid = gm.messageId
      UserId selfId' = gm.selfId
      UserId senderId = gm.userId
      scope = conversationScopeFor gm.groupId
  now' <- liftIO getCurrentTime
  -- Every conversation uses one chronological stream.  The normal path is a
  -- gap-free active compartment suffix followed by its exact raw tail.  If no
  -- projection is ready, or its materialization is unavailable, the global
  -- emergency fallback reads the immutable ledger from the beginning and lets
  -- ContextPolicy retain as much as the selected model's token budget allows.
  -- No mention/participation lane and no fixed message count survive here.
  let fallbackWatermarks = historyTokenWatermarks defaultContextLimits multimodal'
      rawCollectionLimit = maybe fallbackWatermarks.htwHigh (.htwHigh) materializationWatermarks
      collectRawFallback reason = do
        (raw, _) <- fetchBoundedPromptTail scope (MessageCursor 0) mid s.clearedAt rawCollectionLimit
        pure ([], map (.history) raw, Nothing, Just reason)
      collectProjectionFallback reason covered = do
        (raw, _) <- fetchBoundedPromptTail scope (last covered).activeRange.srEnd mid s.clearedAt rawCollectionLimit
        pure
          ( applyBaseCompartmentTiers now' (map contextCompartmentFromActive covered),
            map (.history) raw,
            Nothing,
            Just reason
          )
  (compartments', transcript', materializationVersion, materializationReason) <- case readMode of
    RawLedgerEmergency -> do
      logAttention "context: global raw-ledger emergency reader enabled" $
        object ["group_id" .= gid]
      collectRawFallback "operator_forced_raw_fallback"
    TieredContext -> do
      active <- listActiveCompartments scope
      let visibleAfterClear = case s.clearedAt of
            Nothing -> active
            Just cleared -> filter ((> cleared) . (.activeStartedAt)) active
          covered = latestGapFreeSuffix visibleAfterClear
          watermarks = fromMaybe fallbackWatermarks materializationWatermarks
      case covered of
        [] -> do
          logInfo "context: no active compartment; using token-budgeted raw fallback" $
            object ["group_id" .= gid]
          collectRawFallback "raw_fallback_no_compartments"
        _ | mutationMode == ReadOnlyPreview ->
          collectProjectionFallback "read_only_preview" covered
        _ -> do
          when (any (.activeGapBefore) (drop 1 covered)) $
            logAttention "context: invalid gap inside selected compartment suffix" $
              object ["group_id" .= gid]
          materializeResult <-
            trySync $
              materializeTieredHistory
                scope
                mid
                s.clearedAt
                now'
                watermarks
                covered
          case materializeResult of
            Left err -> do
              logAttention "context: tiered materialization failed; using last-known-good projection" $
                object ["group_id" .= gid, "error" .= T.pack (show err)]
              collectProjectionFallback "last_known_good_projection_fallback" covered
            Right (materialized, rawTail, tailDropped) -> do
              -- ADR 001 fail-soft contract: answering from a truncated tail is
              -- allowed, but never silently.  These rows are in the immutable
              -- ledger and stay recoverable; the historian's token-pressure
              -- capture is what shrinks this window again.
              when tailDropped $
                logAttention "context: bounded tail dropped rows not yet owned by a compartment" $
                  object
                    [ "group_id" .= gid,
                      "materialization_end_seq" .= materialized.cmEndCursor.ingestSeq,
                      "tail_start_seq" .= fmap (.cursor.ingestSeq) (listToMaybe rawTail),
                      "tail_tokens" .= rawTailTokens rawTail,
                      "high_watermark" .= watermarks.htwHigh
                    ]
              pure
                ( materializedCompartments covered materialized,
                  map (.history) rawTail,
                  Just materialized.cmRevision,
                  Just materialized.cmReason
                )
  pinnedItems' <- fetchMessagesByIdsInScope scope s.pinned
  -- Injection is capped to the freshest entries per scope: the block
  -- is in the volatile tail, re-tokenised at full price every
  -- dispatch, and a scope at the 30-entry cap was costing thousands
  -- of uncached tokens.  The long tail stays reachable through
  -- memory_list / context_search.
  groupMems <- listRecentMemories (groupMemoryNamespace scope) memoryInjectCap
  userMems <- listRecentMemories (userMemoryNamespace scope senderId) memoryInjectCap
  replyCtx0 <- case (\(MessageId target) -> target) <$> gm.replyToMessageId of
    Nothing -> pure Nothing
    Just rid -> do
      mHist <- fetchMessageInScope scope rid
      case mHist of
        Nothing -> pure Nothing
        Just h -> do
          files <- DBFiles.fetchFilesForMessageInScope scope h.messageId
          -- Expand a quoted 转发聊天记录: its contents were filed by
          -- the forward worker as child rows.  Empty for ordinary
          -- messages — one cheap indexed lookup either way.
          kids <- fetchForwardChildrenInScope scope h.messageId maxForwardLines
          pure (Just (h, files, kids))
  -- Context stickers the caption worker has already described read
  -- as [sticker#<id>: <caption>] instead of an opaque [sticker]
  -- marker — a non-multimodal model gets to "see" them, and a
  -- multimodal one saves image budget for real photos.
  let ctxIds =
        map (.messageId) $
          transcript'
            <> pinnedItems'
            <> maybe [] (\(r, _, kids) -> r : kids) replyCtx0
  capMap <- stickerCaptionsFor ctxIds
  -- Same idea for ordinary photos and videos (Max.MediaCaption):
  -- described media renders as [image#<id>: <简介>] / [video#<id>:
  -- <简介>], so the model knows what's behind a marker without
  -- spending a view_image/view_video call on it.
  imgCaps <- imageCaptionsFor ctxIds
  vidCaps <- videoCaptionsFor ctxIds
  let enrich = applyVideoCaptions vidCaps . tagMediaMarkers . applyStickerCaptions capMap
      transcript'' = map enrich transcript'
      pinnedItems'' = map enrich pinnedItems'
      replyCtx' = fmap (\(r, f, kids) -> (enrich r, f, map enrich kids)) replyCtx0
      replyItems = maybe [] (\(r, _, kids) -> r : kids) replyCtx'
  -- Unrelated pictures in the ambient chatter are attention magnets:
  -- only images the user is plausibly pointing at (reply target, the
  -- trigger itself, pins) go inline.  Everything else keeps a text
  -- marker, upgraded with the message id ("[image#123]") so the model
  -- can pull it via the view_image tool when it actually matters.
  transcriptCtx <-
    if multimodal'
      then do
        let inlineIds =
              Set.fromList (mid : map (.messageId) (replyItems <> pinnedItems''))
            taggable =
              [ h.messageId
              | h <- transcript'',
                h.messageId `Set.notMember` inlineIds
              ]
        tagIds <- messagesWithImages taggable
        pure (map (tagImageMarkers imgCaps tagIds) transcript'')
      else pure transcript''
  -- The trigger itself may BE a 转发聊天记录 (typical in private
  -- chat, where any message dispatches).  Its children are being
  -- fetched by the forward worker right now — wait for them, then
  -- expand inline under the current message like the quoted-reply
  -- path does.
  triggerKids <-
    if any isForwardNode gm.body.nodes
      then do
        waitForTriggerForward mid
        -- Same enrichment as every other rendered line — in
        -- particular nested forwards must carry their [forward#<id>]
        -- handle so the model can view_forward one level deeper.
        map enrich <$> fetchForwardChildrenInScope scope mid maxForwardLines
      else pure []
  images' <-
    if multimodal'
      then do
        -- The trigger's images were enqueued moments ago and may
        -- still be downloading — hold the turn until they land so
        -- the model actually sees them.  (Older context images are
        -- either long since fetched or permanently failed; no point
        -- waiting on those.)
        let expected = downloadableImageCount gm.body
        when (expected > 0) $ waitForTriggerImages mid expected
        -- Budget priority: the reply target is what the user is
        -- pointing at, then pins (explicit user signals).  Ambient
        -- recency is deliberately NOT a candidate any more — see the
        -- marker-tagging pass above.
        loadPromptImages
          tz'
          selfId'
          mid
          (Set.fromList (map (.messageId) replyItems))
          (dedupById (replyItems <> pinnedItems''))
      else pure []
  -- Videos the user is pointing at (the trigger itself, or the quoted
  -- message) attach whole — same policy as images.  Ambient videos
  -- keep their [video#<id>] marker for view_video.  The video worker
  -- (same pool as images) downloads them into the blob store at
  -- receive time; the trigger's own video may still be in flight, so
  -- wait for it like we do for images.
  videos' <-
    if multimodal'
      then do
        let expectedVids = downloadableVideoCount gm.body
        when (expectedVids > 0) (waitForTriggerVideos mid expectedVids)
        let cands =
              maybe
                []
                (\(r, _, _) -> [(r.messageId, "[↩ quoted message] 里的视频")])
                replyCtx0
                <> [(mid, "[current message] 里的视频") | expectedVids > 0]
        take maxPromptVideos . concat <$> traverse loadMessageVideos cands
      else pure []
  pure $
    ContextSnapshot
      { csCandidates =
          ContextCandidates $
            PromptInputs
            { defaultPersona = defaultPersona,
              session = s,
              triggerMessage = gm,
              transcript = transcriptCtx,
              compartments = compartments',
              historyTurns = historyTurns',
              inFlight = inFlight',
              pinnedItems = pinnedItems'',
              replyCtx = replyCtx',
              triggerForward = triggerKids,
              multimodal = multimodal',
              outputCapabilities = outputCaps,
              origin = origin',
              groupBrief = brief,
              groupMemories = groupMems,
              userMemories = userMems,
              images = images' <> videos',
              skills = skills',
              now = now',
              tz = tz'
            },
        csMaterializationVersion = materializationVersion,
        csMaterializationReason = materializationReason
      }

-- | Poll until the image worker has recorded all of the trigger's
-- downloadable images ('message_images' rows are inserted only after
-- a download completes), so the prompt doesn't race the fetch and
-- silently drop the picture the user is asking about.  Bounded: a
-- failed download never inserts its row, so we give up after
-- 'waitImagesMaxMs' and build the prompt with whatever landed.
waitForTriggerImages ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Int64 -> -- trigger message_id
  Int -> -- expected downloadable image count
  Eff es ()
waitForTriggerImages mid expected = go 0
  where
    stepMs = 300
    waitImagesMaxMs = 30_000
    go elapsed
      | elapsed >= waitImagesMaxMs =
          logAttention "prompt: trigger images still missing after wait" $
            object ["message_id" .= mid, "expected" .= expected]
      | otherwise = do
          rows <-
            query
              "SELECT count(*) FROM message_images WHERE message_id = ?"
              (Only mid)
          case rows of
            [Only (n :: Int64)] | n >= fromIntegral expected -> pure ()
            _ -> do
              liftIO (threadDelay (stepMs * 1000))
              go (elapsed + stepMs)

-- | Is this segment a 转发聊天记录 container?
isForwardNode :: Node 'Canonical -> Bool
isForwardNode NForward {} = True
isForwardNode _ = False

-- | At most this many whole videos attached per prompt (trigger +
-- quoted) — they're far heavier than images.
maxPromptVideos :: Int
maxPromptVideos = 2

-- | Mirror of 'waitForTriggerImages' for the trigger's own videos:
-- poll until the worker has landed all expected 'message_videos'
-- rows.  Videos are bigger, so the deadline is longer; a failed or
-- oversized download never inserts its row and we give up quietly.
waitForTriggerVideos ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Int64 -> -- trigger message_id
  Int -> -- expected downloadable video count
  Eff es ()
waitForTriggerVideos mid expected = go 0
  where
    stepMs = 500
    waitVideosMaxMs = 60_000
    go elapsed
      | elapsed >= waitVideosMaxMs =
          logAttention "prompt: trigger videos still missing after wait" $
            object ["message_id" .= mid, "expected" .= expected]
      | otherwise = do
          rows <-
            query
              "SELECT count(*) FROM message_videos WHERE message_id = ?"
              (Only mid)
          case rows of
            [Only (n :: Int64)] | n >= fromIntegral expected -> pure ()
            _ -> do
              liftIO (threadDelay (stepMs * 1000))
              go (elapsed + stepMs)

-- | Load a message's downloaded videos from the blob store as prompt
-- attachments.  Empty when the message has none (or the worker hasn't
-- caught up) — the [video#<id>] marker stays.
loadMessageVideos ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  (Int64, Text) -> -- (message_id, attachment label prefix, sans colon)
  Eff es [PromptImage]
loadMessageVideos (mid, label) = do
  rows <-
    query
      "SELECT v.mime_type, v.sha256, v.duration_seconds \
      \  FROM message_videos mv \
      \  JOIN videos v USING (sha256) \
      \  WHERE mv.message_id = ? \
      \  ORDER BY mv.seg_index"
      (Only mid)
  fmap concat . traverse loadOne $ (rows :: [(Text, Text, Maybe Double)])
  where
    -- The probed duration goes into the label: the model's own
    -- duration perception from sampled frames is unreliable (a 29s
    -- clip once read back as "2.1秒").
    loadOne (mime, sha, mDur) = case blobRefFromSha256 sha of
      Nothing -> do
        logAttention "prompt: invalid video blob ref" $ object ["sha256" .= sha]
        pure []
      Just ref -> do
        eres <- try @IOException (readBlob ref)
        case eres of
          Left e -> do
            logAttention "prompt: video read failed" $
              object ["sha256" .= sha, "error" .= T.pack (show e)]
            pure []
          Right bytes ->
            pure
              [ PromptImage
                  (label <> maybe "" (\d -> "（时长 " <> fmtDurationSec d <> "）") mDur <> ":")
                  ("data:" <> mime <> ";base64," <> TE.decodeUtf8 (B64.encode bytes))
              ]

-- | Poll until the forward worker has landed at least one child row
-- for the trigger's 转发聊天记录 (the whole chain arrives in one
-- @get_forward_msg@ round-trip, so "any child" means "all of them").
-- Bounded: a failed fetch never inserts rows, so give up after
-- 'waitForwardMaxMs' and let the prompt show the bare marker.
waitForTriggerForward ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  Int64 -> -- trigger message_id
  Eff es ()
waitForTriggerForward mid = go 0
  where
    stepMs = 300
    waitForwardMaxMs = 10_000
    go elapsed
      | elapsed >= waitForwardMaxMs =
          logAttention "prompt: trigger forward still unexpanded after wait" $
            object ["message_id" .= mid]
      | otherwise = do
          rows <-
            query
              "SELECT count(*) FROM message_relations containment \
              \ JOIN messages container \
              \   ON container.canonical_message_id = containment.target_canonical_message_id \
              \ WHERE containment.relation_kind = 'contained_in' \
              \   AND container.message_id = ?"
              (Only mid)
          case rows of
            [Only (n :: Int64)] | n > 0 -> pure ()
            _ -> do
              liftIO (threadDelay (stepMs * 1000))
              go (elapsed + stepMs)

-- | Upgrade bare opaque-media display markers to id-carrying handles
-- the model can pass to a tool: @[forward]@ → @[forward#\<mid\>]@
-- (view_forward) and @[video]@ → @[video#\<mid\>]@ (view_video).  The
-- id is the containing message's own id — that's what forward child
-- rows are keyed under and what the video tool reads segments from.
tagMediaMarkers :: HistoryItem -> HistoryItem
tagMediaMarkers h = h {renderedText = foldr tag h.renderedText ["forward", "video"]}
  where
    tag kind t =
      T.replace
        ("[" <> kind <> "]")
        ("[" <> kind <> "#" <> T.pack (show h.messageId) <> "]")
        t

-- | Everyone appearing in this turn's context, QQ号 ↔ display name.
-- Rendered text shows mentions as [@#<QQ号>] tokens (the wire
-- event carries), so without this table the model cannot tell who
-- @123456 is — including itself.
contextRoster :: PromptInputs -> [(Int64, Text)]
contextRoster pi' =
  let UserId selfId' = pi'.triggerMessage.selfId
      UserId senderId = pi'.triggerMessage.userId
   in dedupeRoster $
        (selfId', "Max（你自己）")
          : (senderId, triggerSenderName pi'.triggerMessage)
          : [ (h.userId, displayName selfId' h)
            | h <-
                pi'.transcript
                  <> pi'.pinnedItems
                  <> maybe [] (\(r, _, _) -> [r]) pi'.replyCtx,
              h.userId /= selfId'
            ]

-- | Keep the first (name) entry per user id.
dedupeRoster :: [(Int64, Text)] -> [(Int64, Text)]
dedupeRoster = go Set.empty
  where
    go _ [] = []
    go seen ((u, n) : rest)
      | u `Set.member` seen = go seen rest
      | otherwise = (u, n) : go (Set.insert u seen) rest

-- | Which of the given messages have at least one stored image —
-- the candidates for @[image#\<id\>]@ marker tagging.
messagesWithImages ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Set.Set Int64)
messagesWithImages [] = pure Set.empty
messagesWithImages ids = do
  rows <-
    query
      "SELECT DISTINCT message_id FROM message_images WHERE message_id IN ?"
      (Only (In ids))
  pure (Set.fromList [m | Only m <- rows])

-- | Upgrade the plain @[image]@ markers of a withheld-image message
-- to @[image#\<message_id\>]@ so the model has a handle to pass to
-- the view_image tool — with the caption appended
-- (@[image#\<id\>: \<简介\>]@) when the media captioner has described
-- that picture.  Markers are consumed left-to-right in seg order,
-- matching the caption list.  Runs after sticker-caption
-- substitution, so captioned stickers are already out of marker form
-- (and sticker shas are excluded from the caption map).
tagImageMarkers :: Map.Map Int64 [Text] -> Set.Set Int64 -> HistoryItem -> HistoryItem
tagImageMarkers caps tagged h
  | h.messageId `Set.member` tagged =
      h {renderedText = go (Map.findWithDefault [] h.messageId caps) h.renderedText}
  | otherwise = h
  where
    handle = "[image#" <> T.pack (show h.messageId)
    go cs t = case T.breakOn "[image]" t of
      (_, "") -> t
      (pre, suf) ->
        let rest = T.drop (T.length ("[image]" :: Text)) suf
            (mark, cs') = case cs of
              (c : more) -> (handle <> ": " <> T.take 120 c <> "]", more)
              [] -> (handle <> "]", [])
         in pre <> mark <> go cs' rest

-- | Append captions to the @[video#\<id\>]@ handles 'tagMediaMarkers'
-- produced: @[video#\<id\>: \<简介\>]@.  Successive markers consume
-- successive captions (seg order), the common case being one video
-- per message.
applyVideoCaptions :: Map.Map Int64 [(Maybe Text, Maybe Text)] -> HistoryItem -> HistoryItem
applyVideoCaptions caps h = case Map.lookup h.messageId caps of
  Nothing -> h
  Just ds -> h {renderedText = go ds h.renderedText}
  where
    marker = "[video#" <> T.pack (show h.messageId) <> "]"
    go [] t = t
    go ((mDesc, mAttr) : ds) t = case T.breakOn marker t of
      (_, "") -> t
      (pre, suf) ->
        pre
          <> "[video#"
          <> T.pack (show h.messageId)
          <> maybe "" (\d -> ": " <> T.take 120 d) mDesc
          <> "]"
          <> maybe "" (\a -> "(" <> a <> ")") mAttr
          <> go ds (T.drop (T.length marker) suf)

-- | Captions of already-described ordinary images (sticker shas
-- excluded — those substitute via 'applyStickerCaptions') appearing
-- in the given messages, in seg_index order per message.
imageCaptionsFor ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Map.Map Int64 [Text])
imageCaptionsFor [] = pure Map.empty
imageCaptionsFor ids = do
  rows <-
    query
      "SELECT mi.message_id, i.description \
      \  FROM message_images mi \
      \  JOIN images i USING (sha256) \
      \  WHERE mi.message_id IN ? \
      \    AND i.description IS NOT NULL \
      \    AND NOT EXISTS (SELECT 1 FROM stickers s WHERE s.sha256 = mi.sha256) \
      \  ORDER BY mi.message_id, mi.seg_index"
      (Only (In ids))
  pure (Map.fromListWith (flip (<>)) [(m, [d]) | (m, d) <- rows :: [(Int64, Text)]])

-- | Same for videos: probed duration + first-frame description,
-- joined into one caption ("时长 29 秒，首帧是…").  Duration alone
-- still renders — it's known at ingest, before the captioner runs,
-- and the model's own duration perception is unreliable.
videoCaptionsFor ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Map.Map Int64 [(Maybe Text, Maybe Text)])
videoCaptionsFor [] = pure Map.empty
videoCaptionsFor ids = do
  rows <-
    query
      "SELECT mv.message_id, v.description, v.duration_seconds \
      \  FROM message_videos mv \
      \  JOIN videos v USING (sha256) \
      \  WHERE mv.message_id IN ? \
      \    AND (v.description IS NOT NULL OR v.duration_seconds IS NOT NULL) \
      \  ORDER BY mv.message_id, mv.seg_index"
      (Only (In ids))
  pure $
    Map.fromListWith
      (flip (<>))
      [ (m, [capText mDesc mDur])
      | (m, mDesc, mDur) <- rows :: [(Int64, Maybe Text, Maybe Double)]
      ]
  where
    -- (colon-slot description, paren-slot attribute) — duration is
    -- metadata, not content, so it rides the attribute group:
    -- "[video#7407: 首帧…](29秒)".
    capText mDesc mDur = (mDesc, fmtDurationSec <$> mDur)

-- | Captions of already-described stickers appearing in the given
-- messages, in seg_index order per message.
stickerCaptionsFor ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Map.Map Int64 [(Int64, Text)])
stickerCaptionsFor [] = pure Map.empty
stickerCaptionsFor ids = do
  rows <-
    query
      "SELECT mi.message_id, s.id, s.description \
      \  FROM message_images mi \
      \  JOIN stickers s USING (sha256) \
      \  WHERE mi.message_id IN ? \
      \    AND s.description IS NOT NULL AND NOT s.banned \
      \  ORDER BY mi.message_id, mi.seg_index"
      (Only (In ids))
  pure (Map.fromListWith (flip (<>)) [(m, [(sid, d)]) | (m, sid, d) <- rows :: [(Int64, Int64, Text)]])

-- | Swap sticker markers in a history item's rendered text for their
-- captions.  Markers are consumed left-to-right in seg order;
-- @[image]@ is accepted too because rows persisted before sub_type
-- survived parsing rendered stickers that way.
applyStickerCaptions :: Map.Map Int64 [(Int64, Text)] -> HistoryItem -> HistoryItem
applyStickerCaptions caps h = case Map.lookup h.messageId caps of
  Nothing -> h
  Just ds -> h {renderedText = replaceStickerMarkers ds h.renderedText}

-- | Swap opaque sticker markers for "[sticker#\<id\>: \<caption\>]".  The
-- @\#\<id\>@ is @stickers.id@ — the same handle the model writes back
-- to *send* that sticker, so what it reads inbound and what it emits
-- outbound share one form.
--
-- Only sticker-specific markers are eligible when the text has any:
-- a photo's @[image]@ in a mixed photo+sticker message must not
-- swallow the sticker's caption.  Rows persisted before sub_type
-- survived parsing rendered stickers as @[image]@ too, so when no
-- sticker-specific marker exists we fall back to consuming those.
replaceStickerMarkers :: [(Int64, Text)] -> Text -> Text
replaceStickerMarkers ds0 t0 = go ds0 t0
  where
    -- "[动画表情]" is the pre-rename form still present in old rows.
    stickerMarkers = ["[sticker]", "[动画表情]", "[mface]"] :: [Text]
    markers
      | any (`T.isInfixOf` t0) stickerMarkers = stickerMarkers
      | otherwise = ["[image]"]
    go [] rest = rest
    go ((sid, d) : ds) rest = case firstMarker rest of
      Nothing -> rest
      Just (pre, post) ->
        pre <> "[sticker#" <> T.pack (show sid) <> ": " <> T.take 80 d <> "]" <> go ds post
    firstMarker rest =
      case sortOn fst [(T.length pre, m) | m <- markers, Just pre <- [findSub m rest]] of
        [] -> Nothing
        ((i, m) : _) -> Just (T.take i rest, T.drop (i + T.length m) rest)
    findSub m s = case T.breakOn m s of
      (pre, suf) | not (T.null suf) -> Just pre
      _ -> Nothing

-- | Keep first occurrence of each message id.
dedupById :: [HistoryItem] -> [HistoryItem]
dedupById = go Set.empty
  where
    go _ [] = []
    go seen (h : rest)
      | h.messageId `Set.member` seen = go seen rest
      | otherwise = h : go (Set.insert h.messageId seen) rest

-- | Total images attached to one prompt.  Keeps worst-case context
-- growth bounded (8 × ~1 MiB of base64) while covering the common
-- "look at these screenshots" flows.
maxPromptImages :: Int
maxPromptImages = 8

-- | Per-image byte cap; anything larger is skipped (stays a text
-- marker) rather than blowing up the request body.  NB: some
-- endpoints cap lower than this (e.g. Anthropic at 5 MB/image) and
-- will reject the request themselves.
maxImageBytes :: Int
maxImageBytes = 20 * 1024 * 1024

-- | Load up to 'maxPromptImages' images for the trigger + context
-- messages via one 'message_images' join.  The trigger's images
-- claim the budget first, then @candidates@ in the given priority
-- order.  Selected context images are re-sorted chronologically for
-- display and the trigger's go last, closest to the question.
-- Images whose local file is missing (worker hasn't caught up) or
-- oversized are skipped.
loadPromptImages ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  TimeZone -> -- display timezone for the image labels' HH:MM
  Int64 -> -- bot self id (for display names in labels)
  Int64 -> -- trigger message_id
  Set.Set Int64 -> -- message ids belonging to the quoted reply (incl. forward children)
  [HistoryItem] -> -- context candidates, priority order, deduped
  Eff es [PromptImage]
loadPromptImages tz' selfId' mid replyIds candidates = do
  let candidates' = filter (\h -> h.messageId /= mid) candidates
      ids = mid : map (.messageId) candidates'
  rows <-
    query
      "SELECT mi.message_id, i.mime_type, i.sha256 \
      \  FROM message_images mi \
      \  JOIN images i ON i.sha256 = mi.sha256 \
      \  WHERE mi.message_id IN ? \
      \  ORDER BY mi.message_id, mi.seg_index"
      (Only (In ids))
  let byMsg =
        Map.fromListWith
          (flip (<>))
          [(m, [(mime, path)]) | (m, mime, path) <- rows :: [(Int64, Text, Text)]]
      imagesOf i = Map.findWithDefault [] i byMsg
      picked =
        take maxPromptImages $
          map Left (imagesOf mid)
            <> [Right (h, mp) | h <- candidates', mp <- imagesOf h.messageId]
      (triggerPicked, contextUnsorted) = partitionEithers picked
      contextPicked = sortOn (\(h, _) -> h.receivedAt) contextUnsorted
  ctxImgs <- concat <$> traverse (uncurry loadCtx) contextPicked
  trigImgs <- concat <$> traverse (loadOne "[current message] 里的图片:") triggerPicked
  pure (ctxImgs <> trigImgs)
  where
    loadCtx h mp =
      -- The quoted message's images get an unmistakable label — "which
      -- picture are you asking about" must not depend on the model
      -- correlating timestamps.
      let label
            | h.messageId `Set.member` replyIds =
                "[↩ quoted message（"
                  <> fmtHM tz' h.receivedAt
                  <> " "
                  <> displayName selfId' h
                  <> "）] 里的图片:"
            | otherwise =
                "["
                  <> fmtHM tz' h.receivedAt
                  <> " "
                  <> displayName selfId' h
                  <> "] 消息里的图片:"
       in loadOne label mp
    loadOne label (mime, sha) = case blobRefFromSha256 sha of
      Nothing -> do
        logAttention "prompt: invalid image blob ref" $ object ["sha256" .= sha]
        pure []
      Just ref -> do
        eres <- try @IOException (readBlob ref)
        case eres of
          Right bytes0 -> do
            (mime', bytes) <- liftIO (prepareImageForLLM mime bytes0)
            if BS.length bytes > maxImageBytes
              then do
                logAttention "prompt: image skipped (too large)" $
                  object ["sha256" .= sha, "bytes" .= BS.length bytes]
                pure []
              else
                let b64 = TE.decodeUtf8 (B64.encode bytes)
                 in pure [PromptImage label ("data:" <> mime' <> ";base64," <> b64)]
          Left e -> do
            logAttention "prompt: image read failed" $
              object ["sha256" .= sha, "error" .= T.pack (show e)]
            pure []

-- | Pure transformation from fetched inputs to the chat-message list
-- the LLM sees.
--
-- Structure:
--
--   * @system@ message: persona + format guide.
--   * One chronological stream of compartments plus raw messages.
--   * One final @user@ message containing that stream, the reply chain,
--     pinned messages, and the current trigger.
renderContext :: PromptInputs -> [ChatMessage]
renderContext pi' =
  let UserId selfId' = pi'.triggerMessage.selfId
      GroupId gidRaw = pi'.triggerMessage.groupId
      senderName = triggerSenderName pi'.triggerMessage
      memBlock =
        renderMemories
          pi'.tz
          (isPrivateChat pi'.triggerMessage.groupId)
          senderName
          pi'.groupMemories
          pi'.userMemories
      effectivePersona = fromMaybe pi'.defaultPersona pi'.session.persona
      roster = contextRoster pi'
      envText =
        T.intercalate "\n" $
          [ "[environment]",
            "  现在：" <> fmtEnvStamp pi'.tz pi'.now,
            if isPrivateChat pi'.triggerMessage.groupId
              then "  场景：与 " <> senderName <> " 一对一私聊"
              else
                (if pi'.outputCapabilities.canMention then "  群号：" else "  会话 ID：")
                  <> T.pack (show gidRaw)
          ]
            <> map ("  " <>) pi'.groupBrief
            <> ["  当前模型：" <> pi'.session.model]
            <> [ "  成员对照（[@#QQ号] 即 @某人）："
                   <> T.intercalate "、" ["[@#" <> T.pack (show u) <> "]=" <> n | (u, n) <- roster]
               | pi'.outputCapabilities.canMention
               ]
      -- Questions somebody else's turn is already handling never reach
      -- the model, whichever shape we build.
      visible = dropInFlight selfId' pi'.inFlight pi'.transcript
      -- Flat: everything goes in the user body.  Turns: everything up
      -- to the bot's last message becomes turns, the rest rejoins the
      -- user body so the turn list ends on an assistant.
      (turnRows, bodyRows)
        | pi'.historyTurns = splitTrailingUser selfId' visible
        | otherwise = ([], visible)
      mTranscript
        | pi'.historyTurns = if null bodyRows then Nothing else Just bodyRows
        | otherwise = Just bodyRows
      userBody =
        renderUser
          pi'.tz
          pi'.now
          selfId'
          pi'.origin
          pi'.compartments
          mTranscript
          envText
          memBlock
          pi'.replyCtx
          pi'.pinnedItems
          pi'.triggerForward
          pi'.triggerMessage
      -- If we have inline image bytes, attach them as a multimodal
      -- content-block message, each prefixed with a label naming its
      -- source message; otherwise fall back to plain text (which
      -- still has @[image]@ markers in the body).
      --
      -- Block layout: the first label is folded into the body text
      -- and every other label sits between two images, so no two
      -- text blocks are ever adjacent — the most conservative shape
      -- for strict OpenAI-compatible providers.
      -- The data URL's mime prefix decides the wire block type —
      -- pointed-at videos ride the same attachment list as images.
      mediaBlock u
        | "data:video/" `T.isPrefixOf` u = VideoDataUrl u
        | otherwise = ImageDataUrl u
      userMessage = case pi'.images of
        [] -> MsgUser userBody
        (i0 : rest) ->
          MsgUserBlocks $
            TextBlock (userBody <> "\n\n" <> i0.piLabel)
              : mediaBlock i0.piDataUrl
              : concat [[TextBlock i.piLabel, mediaBlock i.piDataUrl] | i <- rest]
      -- Default: system prompt then one user message, nothing else.
      -- Prior bot replies live in the transcript as ordinary lines
      -- rather than 'MsgAssistant' turns — see 'PromptInputs.transcript'
      -- for why the roles were a lie in a group, and note that this
      -- also removes the last way two consecutive same-role messages
      -- could reach a strict provider: there is exactly one of each.
      messages =
        [MsgSystem (systemPrompt pi'.multimodal (isPrivateChat pi'.triggerMessage.groupId) pi'.outputCapabilities effectivePersona pi'.skills)]
          <> historyTurnMessages pi'.tz selfId' turnRows
          <> [userMessage]
   in messages

-- | Pure policy: enforce the selected model's token ceiling.  Optional active
-- memories go first under pressure,
-- followed by the oldest unpinned raw transcript rows; explicit permanent
-- memories are the final degradable source.  Reply targets, pins, the current
-- message, environment, and attached media are protected here.
planContext :: ContextLimits -> ContextSnapshot -> ContextPlan
planContext limits snapshot =
  let initial = csInputs snapshot
      budget = contextBudget limits (not (null initial.images))
      initialMessages = renderContext initial
      initialTokens = estimateMessagesTokens initialMessages
      (selectedContext, drops) = selectContextTo contextCostModel budget.cbPromptTokenLimit initialTokens snapshot.csCandidates
      selected = selectedContext.selectedInputs
      messages = renderContext selected
      estimated = estimateMessagesTokens messages
      withinBudget = estimated <= budget.cbPromptTokenLimit
   in ContextPlan
        { cpSelected = selectedContext,
          cpBudget = budget,
          cpEstimatedPromptTokens = estimated,
          cpWithinBudget = withinBudget,
          cpTrace = materializationTrace snapshot <> contextTrace budget selected messages drops withinBudget,
          cpPolicyVersion = contextPolicyVersion,
          cpMaterializationVersion = snapshot.csMaterializationVersion,
          cpMaterializationReason = snapshot.csMaterializationReason
        }

materializationTrace :: ContextSnapshot -> [ContextTrace]
materializationTrace snapshot = case snapshot.csMaterializationVersion of
  Nothing -> []
  Just revision ->
    [ ContextTrace
        "history.materialization"
        0
        ContextIncluded
        ( "revision="
            <> T.pack (show revision)
            <> maybe "" (" reason=" <>) snapshot.csMaterializationReason
        )
    ]

renderContextPlan :: ContextPlan -> [ChatMessage]
renderContextPlan = renderContext . cpInputs

contextCostModel :: ContextCostModel
contextCostModel =
  ContextCostModel
    { ccmMemoryBlockTokens = \inputs ->
        maybe
          0
          estimateTextTokens
          ( renderMemories
              inputs.tz
              (isPrivateChat inputs.triggerMessage.groupId)
              (triggerSenderName inputs.triggerMessage)
              inputs.groupMemories
              inputs.userMemories
          ),
      ccmCompartmentBlockTokens =
        estimateTextTokens
          . T.intercalate "\n"
          . (\inputs -> renderCompartments inputs.tz inputs.compartments)
    }

contextTrace :: ContextBudget -> PromptInputs -> [ChatMessage] -> [PolicyDrop] -> Bool -> [ContextTrace]
contextTrace budget inputs messages drops withinBudget =
  [ ContextTrace
      "prompt.total"
      (estimateMessagesTokens messages)
      (if withinBudget then ContextIncluded else ContextOverBudget)
      (if withinBudget then "within model input budget" else "protected prompt sources exceed model input budget"),
    ContextTrace
      "prompt.system"
      (systemTokens messages)
      ContextIncluded
      "stable persona, scene, format, and tool-use guidance",
    ContextTrace
      "history.raw"
      (sum [estimateTextTokens row.renderedText | row <- inputs.transcript])
      ContextIncluded
      "selected chronological raw transcript",
    ContextTrace
      "history.compartment"
      (sum (map compartmentSelectedTokens inputs.compartments))
      ContextIncluded
      "selected deterministic P1/P2/P3 chronological projections",
    ContextTrace
      "history.compartment.p4"
      0
      (if any ((== TierP4) . (.contextTier)) inputs.compartments then ContextDropped else ContextIncluded)
      "P4 episodes remain searchable and expandable but are omitted from the default prompt",
    ContextTrace
      "reply"
      (replyContextTokens inputs.replyCtx)
      ContextIncluded
      "explicit reply target, attached file metadata, and quoted forward children",
    ContextTrace
      "pin"
      (historyContentTokens inputs.pinnedItems)
      ContextIncluded
      "explicitly pinned source messages",
    ContextTrace
      "trigger_forward"
      (historyContentTokens inputs.triggerForward)
      ContextIncluded
      "forward children attached to the current trigger",
    ContextTrace
      "memory"
      (sum [estimateTextTokens memory.memContent | memory <- inputs.groupMemories <> inputs.userMemories])
      ContextIncluded
      "scoped active and permanent semantic memory",
    ContextTrace
      "environment"
      ( estimateTextTokens inputs.session.model
          + sum (map estimateTextTokens inputs.groupBrief)
          + sum [estimateTextTokens name | (_, name) <- contextRoster inputs]
      )
      ContextIncluded
      "current time, conversation, model, and roster",
    ContextTrace
      "current_message"
      (estimateTextTokens (dispatchText inputs.triggerMessage))
      ContextIncluded
      "protected current trigger",
    ContextTrace
      "attachment"
      budget.cbAttachmentReserve
      ContextReserved
      "conservative reserve applied only when media blocks are attached",
    ContextTrace
      "tool_round"
      budget.cbToolRoundReserve
      ContextReserved
      "reserved for tool schemas and later agent rounds",
    ContextTrace
      "output"
      budget.cbReservedOutputTokens
      ContextReserved
      "profile completion limit tracked separately from the input ceiling"
  ]
    <> [ ContextTrace source tokens ContextDropped "removed deterministically under token pressure"
       | (source, tokens) <- Map.toAscList (Map.fromListWith (+) [(drop'.pdSource, drop'.pdTokens) | drop' <- drops])
       ]

compartmentSelectedTokens :: ContextCompartment -> Int
compartmentSelectedTokens = maybe 0 estimateTextTokens . selectedCompartmentSummary

systemTokens :: [ChatMessage] -> Int
systemTokens = \case
  MsgSystem content : _ -> estimateTextTokens content + 8
  _ -> 0

historyContentTokens :: [HistoryItem] -> Int
historyContentTokens = sum . map (estimateTextTokens . (.renderedText))

replyContextTokens :: Maybe (HistoryItem, [FileRecord], [HistoryItem]) -> Int
replyContextTokens = \case
  Nothing -> 0
  Just (reply, files, children) ->
    estimateTextTokens reply.renderedText
      + historyContentTokens children
      + sum [estimateTextTokens file.frFileName | file <- files]

-- | How many entries per scope the prompt carries.  Injection policy,
-- not a storage cap — 'Max.Tools.Memory.maxMemoriesPerScope' still
-- governs what a scope may hold.
memoryInjectCap :: Int
memoryInjectCap = 12

-- | The injected memory block, or 'Nothing' when there is nothing
-- remembered (no block at all beats an empty header — zero tokens,
-- and nothing for the model to fixate on).  The framing line matters
-- as much as the content: memories are 背景备忘 the model may
-- silently draw on, not a topic list to bring up.
renderMemories :: TimeZone -> Bool -> Text -> [MemoryItem] -> [MemoryItem] -> Maybe Text
renderMemories tz' private senderName groupMems userMems
  | null groupMems && null userMems = Nothing
  | otherwise =
      Just . T.intercalate "\n" . concat $
        [ [ "[memories — 背景备忘]",
            "仅在与当前话题相关时参考，不要主动提及；记的是写下时的状态，可能已过期，\
            \与对话矛盾时以对话为准（可 memory_update）。只列最近更新的条目，\
            \更早或跨来源的用 context_search 查；只看记忆清单用 memory_list。"
          ],
          if null groupMems
            then []
            else (if private then "本会话:" else "本群:") : map (memoryLine tz') groupMems,
          if null userMems
            then []
            else ("关于当前发言者 <" <> senderName <> ">（本会话）:") : map (memoryLine tz') userMems
        ]

memoryLine :: TimeZone -> MemoryItem -> Text
memoryLine tz' m =
  "  (#"
    <> T.pack (show m.memId.unMemoryId)
    <> "@v"
    <> T.pack (show m.memVersion.unMemoryVersion)
    <> " "
    <> fmtDate tz' m.memUpdatedAt
    <> ") "
    <> oneLine m.memContent

-- | Keep the newest coverage island.  Explicit historical backfill may have
-- produced older active compartments separated from the live historian
-- cursor by raw rows; those projections remain searchable but cannot be
-- rendered as if the gap did not exist.
latestGapFreeSuffix :: [ActiveCompartment] -> [ActiveCompartment]
latestGapFreeSuffix compartments' = drop lastBreak compartments'
  where
    lastBreak =
      foldl
        (\latest (index, compartment) -> if compartment.activeGapBefore then index else latest)
        0
        (zip [0 ..] compartments')

contextCompartmentFromActive :: ActiveCompartment -> ContextCompartment
contextCompartmentFromActive active =
  ContextCompartment
    { contextCompartmentId = active.activeCompartmentId.unCompartmentId,
      contextExpandHandle = active.activeExpandHandle,
      contextStartedAt = active.activeStartedAt,
      contextEndedAt = active.activeEndedAt,
      contextImportance = active.activeImportance,
      contextConfidence = active.activeConfidence,
      contextMaterializationVersion = active.activeMaterializationVersion,
      contextSummaryP1 = active.activeSummaryP1,
      contextSummaryP2 = active.activeSummaryP2,
      contextSummaryP3 = active.activeSummaryP3,
      contextTier = TierP1
    }

contextPolicyVersion :: Text
contextPolicyVersion = "context-policy/v3"

-- | The returned 'Bool' is the coverage-loss signal: 'True' means the bounded
-- tail fetch stopped before reaching the materialization end cursor, so raw
-- rows exist between the last compartment and the oldest returned tail row
-- that this turn cannot see (the historian has not folded them yet).  Callers
-- on that fail-soft path must record an observable attention state.
materializeTieredHistory ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Maybe UTCTime ->
  UTCTime ->
  HistoryTokenWatermarks ->
  [ActiveCompartment] ->
  Eff es (ContextMaterialization, [LedgerItem], Bool)
materializeTieredHistory scope triggerId cleared now' watermarks active = do
  stored <- loadContextMaterialization scope
  current <- case stored of
    Nothing -> publishOrReload Nothing "initial_materialization" active
    Just materialization
      | not (materializationMatches active materialization) -> do
          let retained = filter ((<= materialization.cmEndCursor) . (.srEnd) . (.activeRange)) active
              replacement = if null retained then active else retained
          publishOrReload (Just materialization.cmRevision) "projection_change" replacement
      | otherwise -> pure materialization
  (tailRows, tailTruncated) <-
    fetchBoundedPromptTail scope current.cmEndCursor triggerId cleared watermarks.htwHigh
  if not tailTruncated && rawTailTokens tailRows <= watermarks.htwHigh
    then pure (current, tailRows, False)
    else case targetAtLowWater current tailRows active watermarks.htwLow of
      Nothing -> pure (current, tailRows, tailTruncated)
      Just target -> do
        folded <- publishOrReload (Just current.cmRevision) "high_water" target
        (foldedTail, foldedTruncated) <-
          fetchBoundedPromptTail scope folded.cmEndCursor triggerId cleared watermarks.htwHigh
        pure (folded, foldedTail, foldedTruncated)
  where
    publishOrReload expected reason target = do
      let draft = materializationDraft now' watermarks.htwHigh reason target
      publishContextMaterialization scope expected draft >>= \case
        Just materialization -> pure materialization
        Nothing ->
          loadContextMaterialization scope >>= \case
            Just winner -> pure winner
            Nothing -> error "context materialization CAS lost without a stored winner"

materializationMatches :: [ActiveCompartment] -> ContextMaterialization -> Bool
materializationMatches active materialization =
  materialization.cmPolicyVersion == contextPolicyVersion
    && not (null owned)
    && length owned == length materialization.cmItems
    && (last owned).activeRange.srEnd == materialization.cmEndCursor
    && expectedItems == materialization.cmItems
  where
    owned = filter ((<= materialization.cmEndCursor) . (.srEnd) . (.activeRange)) active
    expectedItems =
      [ MaterializedCompartment
          compartment.activeCompartmentId
          compartment.activeMaterializationVersion
          stored.mcTier
      | (compartment, stored) <- zip owned materialization.cmItems
      ]

targetAtLowWater ::
  ContextMaterialization ->
  [LedgerItem] ->
  [ActiveCompartment] ->
  Int ->
  Maybe [ActiveCompartment]
targetAtLowWater current tailRows active lowWater = do
  let newer = filter ((> current.cmEndCursor) . (.srEnd) . (.activeRange)) active
  _ <- listToMaybe newer
  let chosen =
        fromMaybe
          (last newer)
          ( find
              (\compartment -> rawTailTokens (rowsAfter compartment.activeRange.srEnd) <= lowWater)
              newer
          )
  pure (filter ((<= chosen.activeRange.srEnd) . (.srEnd) . (.activeRange)) active)
  where
    rowsAfter cursor = filter ((> cursor) . (.cursor)) tailRows

materializationDraft :: UTCTime -> Int -> Text -> [ActiveCompartment] -> MaterializationDraft
materializationDraft now' compartmentBudget reason active =
  MaterializationDraft
    { mdEndCursor = (last active).activeRange.srEnd,
      mdPolicyVersion = contextPolicyVersion,
      mdItems = zipWith toStored active tiered,
      mdReason = reason
    }
  where
    tiered = fitCompartmentTiers compartmentBudget (applyBaseCompartmentTiers now' (map contextCompartmentFromActive active))
    toStored source planned =
      MaterializedCompartment
        { mcCompartmentId = source.activeCompartmentId,
          mcProjectionVersion = source.activeMaterializationVersion,
          mcTier = compartmentTierStorageText planned.contextTier
        }

fitCompartmentTiers :: Int -> [ContextCompartment] -> [ContextCompartment]
fitCompartmentTiers tokenLimit = go
  where
    go compartments'
      | sum (map compartmentSelectedTokens compartments') <= tokenLimit = compartments'
      | otherwise = case filter ((/= TierP4) . (.contextTier)) compartments' of
          [] -> compartments'
          candidates ->
            let selected = minimumBy (compare `on` degradationKey) candidates
                degraded = selected {contextTier = succ selected.contextTier}
             in go
                  [ if compartment.contextCompartmentId == selected.contextCompartmentId
                      then degraded
                      else compartment
                  | compartment <- compartments'
                  ]
    degradationKey compartment =
      ( compartment.contextImportance,
        compartment.contextEndedAt,
        compartment.contextMaterializationVersion,
        compartment.contextCompartmentId
      )

materializedCompartments :: [ActiveCompartment] -> ContextMaterialization -> [ContextCompartment]
materializedCompartments active materialization = mapMaybe materialize materialization.cmItems
  where
    byId = Map.fromList [(compartment.activeCompartmentId, compartment) | compartment <- active]
    materialize stored = do
      source <- Map.lookup stored.mcCompartmentId byId
      tier <- compartmentTierFromStorageText stored.mcTier
      pure (contextCompartmentFromActive source) {contextTier = tier}

rawTailTokens :: [LedgerItem] -> Int
rawTailTokens =
  sum
    . map
      (\entry -> 8 + estimateTextTokens entry.history.renderedText)

-- | Collect only the newest token-sized raw tail.  SQL pages are walked
-- backward so an arbitrarily old ledger never has to enter memory merely to
-- be dropped by ContextPolicy.  The final page may overshoot the token target;
-- the pure policy remains the authoritative exact selection boundary.
fetchBoundedPromptTail ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MessageCursor ->
  Int64 ->
  Maybe UTCTime ->
  Int ->
  Eff es ([LedgerItem], Bool)
fetchBoundedPromptTail scope after triggerId cleared tokenLimit = go Nothing [] 0
  where
    go before accumulated used = do
      page <- fetchNewestPromptPageBefore scope after before triggerId cleared promptTailPageSize
      let rows = page.items
          accumulated' = rows <> accumulated
          used' = used + rawTailTokens rows
      case rows of
        [] -> pure (accumulated, False)
        oldest : _
          | page.hasMore && used' < max 1 tokenLimit ->
              go (Just oldest.cursor) accumulated' used'
          | otherwise -> pure (accumulated', page.hasMore)

-- Internal database page size only; never a retained-message boundary.
promptTailPageSize :: Int
promptTailPageSize = 256

compartmentTierStorageText :: CompartmentTier -> Text
compartmentTierStorageText = T.toLower . compartmentTierText

compartmentTierFromStorageText :: Text -> Maybe CompartmentTier
compartmentTierFromStorageText = \case
  "p1" -> Just TierP1
  "p2" -> Just TierP2
  "p3" -> Just TierP3
  "p4" -> Just TierP4
  _ -> Nothing

-- | Drop the messages another turn is already answering.
--
-- Their real reply hasn't been written yet, so each would sit in the
-- context as a question with nothing after it — indistinguishable from
-- one the bot ignored, and the model duly answers it on top of the one
-- it was actually asked.  Both people then get the same answer, one of
-- them twice.
--
-- Hiding rather than annotating: an explanation of why a line should
-- be skipped is one more string in the prompt that the model has to
-- correctly read as not-speech, and the annotation that used to live
-- here failed exactly that way — it came back as the bot's reply.
-- Bot rows are never dropped; nothing puts the bot's own id in flight,
-- but losing its side of the conversation would be the worse failure.
dropInFlight :: Int64 -> Set Int64 -> [HistoryItem] -> [HistoryItem]
dropInFlight botId inFlight =
  filter (\h -> h.userId == botId || h.messageId `Set.notMember` inFlight)

-- | History as real @user@\/@assistant@ turns
-- ('PromptInputs.historyTurns').
--
-- Runs of consecutive same-side rows collapse into one message: the
-- group's chatter is mostly not the bot, so without this a group
-- transcript becomes a long run of consecutive @user@ messages, which
-- strict providers reject.  Non-bot rows keep the same
-- @[HH:MM \<name\> #\<id\>]:@ label the flat shape uses — the role says
-- only \"not the bot\", so in a group with N speakers the label is
-- still doing all the work of saying who spoke.
--
-- Bot rows go in verbatim, deliberately unlabelled: a
-- @[HH:MM Max #id]@ prefix in the assistant slot is the one thing most
-- likely to teach the model to open its own replies that way.  The
-- cost is that the bot's own messages have no quotable id in this
-- shape — the flat transcript is the only one where they do.
historyTurnMessages :: TimeZone -> Int64 -> [HistoryItem] -> [ChatMessage]
historyTurnMessages tz' botId =
  map render . groupBy ((==) `on` isBot)
  where
    isBot h = h.userId == botId
    render hs
      | all isBot hs = MsgAssistant (T.intercalate "\n\n" (map (.renderedText) hs))
      | otherwise = MsgUser (T.intercalate "\n" (map (renderHistoryLine tz' botId) hs))

-- | Split the transcript so the turn list ends on an assistant turn:
-- any non-bot rows trailing the bot's last message go back into the
-- final user message, which is itself a user turn.
--
-- Without this the handover from history to now is two consecutive
-- user messages — precisely the thing this shape exists to avoid, and
-- it happens on every turn where the last thing said wasn't said by
-- the bot, which in a group is most of them.
splitTrailingUser :: Int64 -> [HistoryItem] -> ([HistoryItem], [HistoryItem])
splitTrailingUser botId hs =
  let (revTail, revHead) = span (\h -> h.userId /= botId) (reverse hs)
   in (reverse revHead, reverse revTail)

renderUser ::
  TimeZone ->
  UTCTime -> -- now; the current message carries no timestamp of its own
  Int64 ->
  TriggerOrigin ->
  [ContextCompartment] ->
  -- | The conversation transcript, chronological — or 'Nothing' when
  -- it is being emitted as separate turns and the @[recent messages]@
  -- block should not appear here at all.
  Maybe [HistoryItem] ->
  Text -> -- environment block (volatile; goes after the transcript)
  Maybe Text -> -- memory block (volatile; likewise)
  Maybe (HistoryItem, [FileRecord], [HistoryItem]) ->
  [HistoryItem] -> -- pinned items, in user pin order
  [HistoryItem] -> -- trigger's own forward children (trigger IS a 转发)
  DispatchMessage ->
  Text
renderUser tz' now' selfId' origin' compartments' mTranscript envText mMemBlock replyCtx' pinnedItems' triggerFwd' gm =
  T.intercalate "\n" $
    concat
      [ -- Pinned first so the model sees them as primary context
        if null pinnedItems'
          then []
          else
            [ "[pinned — 长期保留的消息（用户 !pin 或你 pin_message 的），!clear 也不清；过时的用 unpin_message 清理]",
              T.intercalate "\n" (map (renderHistoryLine tz' selfId') pinnedItems'),
              ""
            ],
        renderCompartments tz' compartments',
        case mTranscript of
          Nothing -> []
          Just [] -> ["[recent messages]", "(无历史消息)"]
          Just hs -> "[recent messages]" : map (renderHistoryLine tz' selfId') hs,
        -- Everything above this line is meant to be byte-stable across
        -- dispatches so a provider's prefix cache can cover it; the
        -- clock and the per-turn roster necessarily aren't, so they go
        -- below.  Placing them next to the message they describe reads
        -- better anyway than a clock buried in the system prompt.
        ["", envText],
        maybe [] (\b -> ["", b]) mMemBlock,
        [""],
        case replyCtx' of
          Nothing -> []
          Just (r, files, kids) ->
            "[quoted context]"
              : renderReplyLine tz' selfId' r
              : renderReplyFiles files
                <> renderReplyForward tz' selfId' kids
                <> [""],
        case origin' of
          OriginProactive ->
            [ "[current message — 没人 @ 你，意图识别判断你可能想接话]",
              renderCurrentLine tz' now' gm
            ]
              <> renderReplyForward tz' selfId' triggerFwd'
              <> [ "",
                   "你没有被 @。想接话就接，语气自然点，别表现得像被点名回答问题；\
                   \插话要短，一两句说完，说完就收，别追着展开；\
                   \记得用 [↩#<msgid>] 引用你在回的那条。\
                   \不想接、没什么可说的、或话题跟你无关，就整条回复 [silence]——主动插话宁缺毋滥。"
                 ]
          OriginPoke ->
            [ "[current message — 戳一戳]",
              triggerSenderName gm <> " 戳了戳你。没有文字，这是柔和版的 @，意思通常是\"看一眼上面\"。",
              "",
              "先翻上下文，重点看 TA 自己最近的发言：有可能是刚才有个问题\
              \或话题没 @ 到你（主语不明确没触发你），戳你就是叫你回应它——\
              \找到了就直接回答那条，用 [↩#<msgid>] 引用；也可能是在催你\
              \正在做的事，那就报下进展。\
              \上下文里如果找不到 TA 在等你回应的东西（比如就是逗你、\
              \打个招呼）时，才用 poke 工具戳回去，然后回复 [silence]。"
            ]
          OriginDirect ->
            [ "[current message]",
              renderCurrentLine tz' now' gm
            ]
              <> renderReplyForward tz' selfId' triggerFwd'
              <> [ "",
                   "请回复当前消息。"
                 ]
      ]

renderCompartments :: TimeZone -> [ContextCompartment] -> [Text]
renderCompartments tz' compartments' = case mapMaybe renderOne compartments' of
  [] -> []
  rows ->
    ["[earlier conversation — rebuildable chronological summaries]"]
      <> rows
      <> [""]
  where
    renderOne compartment = do
      summary <- selectedCompartmentSummary compartment
      pure $
        "[episode#"
          <> episodeHandleText compartment.contextExpandHandle
          <> " "
          <> fmtDate tz' compartment.contextStartedAt
          <> ".."
          <> fmtDate tz' compartment.contextEndedAt
          <> " "
          <> compartmentTierText compartment.contextTier
          <> "]: "
          <> oneLine summary

renderHistoryLine :: TimeZone -> Int64 -> HistoryItem -> Text
renderHistoryLine tz' selfId' h =
  "["
    <> fmtHM tz' h.receivedAt
    <> " "
    <> displayName selfId' h
    <> " #"
    <> T.pack (show h.messageId)
    <> "]: "
    <> replyPrefix h
    <> oneLine h.renderedText

renderReplyLine :: TimeZone -> Int64 -> HistoryItem -> Text
renderReplyLine tz' selfId' h =
  "[↩ quoted "
    <> fmtHM tz' h.receivedAt
    <> " "
    <> displayName selfId' h
    <> " #"
    <> T.pack (show h.messageId)
    <> "]: "
    <> replyPrefix h
    <> oneLine h.renderedText

-- | If this message itself quotes another, a "[↩#\<id\>]" handle the
-- model can expand with @get_message_by_id@ (and re-emit to quote the
-- same message).  Empty for non-replies.  This keeps a quote chain
-- walkable one hop at a time instead of recursively pre-expanding it.
replyPrefix :: HistoryItem -> Text
replyPrefix h = maybe "" (\r -> "[↩#" <> T.pack (show r) <> "] ") h.replyTo

-- | The expanded contents of a quoted 转发聊天记录.  Lines carry the
-- original send times; each line is truncated to keep a huge bundle
-- from eating the prompt.
renderReplyForward :: TimeZone -> Int64 -> [HistoryItem] -> [Text]
renderReplyForward _ _ [] = []
renderReplyForward tz' selfId' kids =
  ("  转发记录内容" <> capNote <> ":")
    : map (("    " <>) . T.take 200 . renderHistoryLine tz' selfId') kids
  where
    capNote
      | length kids >= maxForwardLines = "（前 " <> T.pack (show maxForwardLines) <> " 条）"
      | otherwise = ""

-- | How many lines of a quoted forward bundle get expanded.
maxForwardLines :: Int
maxForwardLines = 30

renderReplyFiles :: [FileRecord] -> [Text]
renderReplyFiles [] = []
renderReplyFiles xs =
  "  附带文件（file_id 可直接传给 import_file_to_sandbox）:" : map fileLine xs
  where
    fileLine r =
      "    - file_id="
        <> tquote r.frFileId
        <> ", name="
        <> tquote r.frFileName
        <> sizePart r.frBytesSize
        <> ", ready="
        <> (case r.frBlobRef of Just _ -> "true"; Nothing -> "false")
    sizePart Nothing = ""
    sizePart (Just n) = ", bytes=" <> T.pack (show n)
    tquote t = "\"" <> t <> "\""

-- | The live message, rendered in exactly the shape 'renderHistoryLine'
-- uses.  One format for "a message in this conversation", whether it
-- arrived a minute ago or just now — the format guide documents that
-- one shape, and a second shape for the current line was a small lie
-- the model had to work around.
--
-- Takes the clock because a dispatch message carries no timestamp: it is
-- the message being handled right now, so "now" is its time.
renderCurrentLine :: TimeZone -> UTCTime -> DispatchMessage -> Text
renderCurrentLine tz' now' gm =
  let txt = dispatchTextWithoutSelf gm
      MessageId mid = gm.messageId
   in "["
        <> fmtHM tz' now'
        <> " "
        <> triggerSenderName gm
        <> " #"
        <> T.pack (show mid)
        <> "]: "
        <> T.strip txt

-- | 群名片 > 昵称 > QQ 号 — matching what other members see on
-- screen, so the model calls people what the group calls them.
displayName :: Int64 -> HistoryItem -> Text
displayName selfId' h
  | h.userId == selfId' = "Max"
  | otherwise = bestName h

-- | Same preference order for the live trigger message's sender.
triggerSenderName :: DispatchMessage -> Text
triggerSenderName gm =
  let UserId uid = gm.userId
   in fromMaybe (T.pack (show uid)) (nonBlank gm.senderDisplayName)
  where
    nonBlank (Just t) | not (T.null (T.strip t)) = Just (T.strip t)
    nonBlank _ = Nothing

oneLine :: Text -> Text
oneLine = T.replace "\n" " ⏎ "
