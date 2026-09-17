-- | Read-only context and media collection; no publication capability.
module Max.Prompt.Collect (collectContextPreview, collectContextSnapshot) where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.ByteString qualified as BS (length)
import Data.ByteString.Base64 qualified as B64 (encode)
import Data.Either (partitionEithers)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
  ( Map,
    empty,
    findWithDefault,
    fromListWith,
  )
import Data.Set qualified as Set (Set, fromList, member)
import Data.Text (Text)
import Data.Text qualified as T (pack)
import Data.Text.Encoding qualified as TE (decodeUtf8)
import Data.Time (TimeZone, UTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (In (..), Only (..))
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Exception (IOException, try)
import Effectful.Log (Log, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection, query)
import Max.Context.Media (tagMediaMarkers)
import Max.Context.Types
  ( ContextCandidates (ContextCandidates),
    ContextSnapshot (..),
    ContinuationInput (ciCovered, ciSegments, ciView),
    PromptImage (PromptImage),
    PromptInputs
      ( PromptInputs,
        compartments,
        continuationView,
        defaultPersona,
        groupBrief,
        groupMemories,
        historyTurns,
        images,
        inFlight,
        multimodal,
        now,
        origin,
        outputCapabilities,
        pinnedItems,
        recentTurns,
        replayCovered,
        replaySegments,
        replyCtx,
        session,
        skills,
        transcript,
        triggerForward,
        triggerMessage,
        tz,
        userMemories
      ),
  )
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Files qualified as DBFiles
  ( fetchFilesForMessageInScope,
  )
import Max.DB.History
  ( HistoryItem (canonicalId, receivedAt),
    fetchForwardChildrenInScope,
    fetchMessageInScope,
    fetchMessagesByIdsInScope,
  )
import Max.DB.Media (fetchMediaSegments)
import Max.DB.TurnContinuity (recentTurnDigests)
import Max.Dispatch
  ( DispatchMessage
      ( authorPrincipalId,
        body,
        canonicalId,
        groupId,
        replyTo
      ),
  )
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.IR (Body (..), Node (..), Phase (Canonical))
import Max.ImagePrep (prepareImageForLLM)
import Max.Images
  ( downloadableImageCount,
    downloadableVideoCount,
  )
import Max.MemoryStore
  ( groupMemoryNamespace,
    listRecentMemories,
    userMemoryNamespace,
  )
import Max.Platform.Types
  ( CanonicalMessageId (CanonicalMessageId),
    PrincipalId (PrincipalId),
  )
import Max.Prompt.History
  ( HistorySelection (..),
    collectHistoryProjection,
    loadHistorySource,
  )
import Max.Prompt.Render
  ( applyStickerCaptions,
    dedupById,
    displayName,
    maxForwardLines,
    memoryInjectCap,
    tagImageMarkers,
  )
import Max.Prompt.Request
  ( PromptRequest
      ( prContinuation,
        prGroupBrief,
        prHistoryTurns,
        prInFlight,
        prMultimodal,
        prOrigin,
        prOutputCaps,
        prPersona,
        prSession,
        prSkills,
        prTimeZone,
        prTrigger
      ),
  )
import Max.Session.Types (Session (..))
import Max.Time (fmtDurationSec, fmtHM)
import Max.Turn.Continuity (renderRecentTurn)

-- | Read-only collection. It never publishes a materialization revision or
-- diagnostic row; callers can plan and render the snapshot independently.
collectContextPreview ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  PromptRequest -> Eff es ContextSnapshot
collectContextPreview request = do
  now <- liftIO getCurrentTime
  source <- loadHistorySource request
  history <- collectHistoryProjection "read_only_preview" now request source
  collectContextSnapshot request now history

collectContextSnapshot ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  PromptRequest -> UTCTime -> HistorySelection -> Eff es ContextSnapshot
collectContextSnapshot request now' history = do
  let continuation' = request.prContinuation
      outputCaps = request.prOutputCaps
      defaultPersona = request.prPersona
      multimodal' = request.prMultimodal
      historyTurns' = request.prHistoryTurns
      origin' = request.prOrigin
      tz' = request.prTimeZone
      brief = request.prGroupBrief
      skills' = request.prSkills
      inFlight' = request.prInFlight
      s = request.prSession
      gm = request.prTrigger
  let CanonicalMessageId mid = gm.canonicalId
      PrincipalId senderPrincipal = gm.authorPrincipalId
      scope = conversationScopeFor gm.groupId
  recentTurns' <- map (renderRecentTurn tz') <$> recentTurnDigests scope s.clearedAt now'
  let HistorySelection compartments' transcript' materializationVersion materializationReason = history
  pinnedItems' <- fetchMessagesByIdsInScope scope s.pinned
  -- Injection is capped to the freshest entries per scope: the block
  -- is in the volatile tail, re-tokenised at full price every
  -- dispatch, and a scope at the 30-entry cap was costing thousands
  -- of uncached tokens.  The long tail stays reachable through
  -- memory_list / context_search.
  groupMems <- listRecentMemories (groupMemoryNamespace scope) memoryInjectCap
  userMems <- listRecentMemories (userMemoryNamespace scope senderPrincipal) memoryInjectCap
  replyCtx0 <- case (\(CanonicalMessageId target) -> target) <$> gm.replyTo of
    Nothing -> pure Nothing
    Just rid -> do
      mHist <- fetchMessageInScope scope rid
      case mHist of
        Nothing -> pure Nothing
        Just h -> do
          files <- DBFiles.fetchFilesForMessageInScope scope h.canonicalId
          -- Expand a quoted 转发聊天记录: its contents were filed by
          -- the forward worker as child rows.  Empty for ordinary
          -- messages — one cheap indexed lookup either way.
          kids <- fetchForwardChildrenInScope scope h.canonicalId maxForwardLines
          pure (Just (h, files, kids))
  -- Context stickers the caption worker has already described read
  -- as [sticker#<id>: <caption>] instead of an opaque [sticker]
  -- marker — a non-multimodal model gets to "see" them, and a
  -- multimodal one saves image budget for real photos.
  let ctxIds =
        map (.canonicalId) $
          transcript'
            <> pinnedItems'
            <> maybe [] (\(r, _, kids) -> r : kids) replyCtx0
  capMap <- stickerCaptionsFor ctxIds
  -- Same idea for ordinary photos and videos (Max.MediaCaption):
  -- described media renders as [image#<id>.<seg>: <简介>] /
  -- [video#<id>.<seg>: <简介>], so the model knows what's behind a
  -- marker without spending a view_image/view_video call on it — and
  -- can point at one picture of a message carrying several.
  mediaSegs <- fetchMediaSegments ctxIds
  let enrich = tagMediaMarkers mediaSegs . applyStickerCaptions capMap
      transcript'' = map enrich transcript'
      pinnedItems'' = map enrich pinnedItems'
      replyCtx' = fmap (\(r, f, kids) -> (enrich r, f, map enrich kids)) replyCtx0
      replyItems = maybe [] (\(r, _, kids) -> r : kids) replyCtx'
  -- Unrelated pictures in the ambient chatter are attention magnets:
  -- only images the user is plausibly pointing at (reply target, the
  -- trigger itself, pins) go inline.  Everything else keeps a text
  -- marker, upgraded to an [image#<id>.<seg>] handle so the model can
  -- pull it via the view_image tool when it actually matters.
  let transcriptCtx
        | multimodal' =
            let inlineIds =
                  Set.fromList (mid : map (.canonicalId) (replyItems <> pinnedItems''))
             in [ if h.canonicalId `Set.member` inlineIds then h else tagImageMarkers mediaSegs h
                | h <- transcript''
                ]
        | otherwise = transcript''
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
          mid
          (Set.fromList (map (.canonicalId) replyItems))
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
                (\(r, _, _) -> [(r.canonicalId, "[↩ quoted message] 里的视频")])
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
                recentTurns = recentTurns',
                continuationView = continuation'.ciView,
                replaySegments = continuation'.ciSegments,
                replayCovered = continuation'.ciCovered,
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
              "SELECT count(*) FROM message_images WHERE canonical_message_id = ?"
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
              "SELECT count(*) FROM message_videos WHERE canonical_message_id = ?"
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
      \  WHERE mv.canonical_message_id = ? \
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

-- | Everyone appearing in this turn's context, principal ↔ display name.
--
-- Rendered text shows mentions as @[\@#\<principal_id\>]@ tokens (ADR 004),
-- so without this table the model cannot tell who @[\@#123]@ is — including
-- itself.  It is also the vocabulary the send path rescues @\@显示名@
-- against, so the names the model may write are exactly the names it read.
-- | The roster /line/ is where the model is told which id is its own.  The
-- roster /table/ must stay undecorated, because the same entries resolve the
-- display of a mention the model writes, and a display is shipped content.
stickerCaptionsFor ::
  (WithConnection :> es, IOE :> es) =>
  [Int64] ->
  Eff es (Map.Map Int64 [(Int64, Text)])
stickerCaptionsFor [] = pure Map.empty
stickerCaptionsFor ids = do
  rows <-
    query
      "SELECT mi.canonical_message_id, s.id, s.description \
      \  FROM message_images mi \
      \  JOIN stickers s USING (sha256) \
      \  WHERE mi.canonical_message_id IN ? \
      \    AND s.description IS NOT NULL AND NOT s.banned \
      \  ORDER BY mi.canonical_message_id, mi.seg_index"
      (Only (In ids))
  pure (Map.fromListWith (flip (<>)) [(m, [(sid, d)]) | (m, sid, d) <- rows :: [(Int64, Int64, Text)]])

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
  Int64 -> -- trigger canonical message id
  Set.Set Int64 -> -- canonical ids belonging to the quoted reply (incl. forward children)
  [HistoryItem] -> -- context candidates, priority order, deduped
  Eff es [PromptImage]
loadPromptImages tz' mid replyIds candidates = do
  let candidates' = filter (\h -> h.canonicalId /= mid) candidates
      ids = mid : map (.canonicalId) candidates'
  rows <-
    query
      "SELECT mi.canonical_message_id, i.mime_type, i.sha256 \
      \  FROM message_images mi \
      \  JOIN images i ON i.sha256 = mi.sha256 \
      \  WHERE mi.canonical_message_id IN ? \
      \  ORDER BY mi.canonical_message_id, mi.seg_index"
      (Only (In ids))
  let byMsg =
        Map.fromListWith
          (flip (<>))
          [(m, [(mime, path)]) | (m, mime, path) <- rows :: [(Int64, Text, Text)]]
      imagesOf i = Map.findWithDefault [] i byMsg
      picked =
        take maxPromptImages $
          map Left (imagesOf mid)
            <> [Right (h, mp) | h <- candidates', mp <- imagesOf h.canonicalId]
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
            | h.canonicalId `Set.member` replyIds =
                "[↩ quoted message（"
                  <> fmtHM tz' h.receivedAt
                  <> " "
                  <> displayName h
                  <> "）] 里的图片:"
            | otherwise =
                "["
                  <> fmtHM tz' h.receivedAt
                  <> " "
                  <> displayName h
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
