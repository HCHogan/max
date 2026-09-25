-- | Read-only context and media collection; no publication capability.
module Max.Prompt.Collect (collectContextPreview) where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.ByteString qualified as BS (length)
import Data.ByteString.Base64 qualified as B64 (encode)
import Data.Either (partitionEithers)
import Data.Maybe (mapMaybe)
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
  ( ContextSnapshot (..),
    PromptImage (..),
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
import Max.LLM.Types (ContentBlock (ImageDataUrl))
import Max.Media.Prepare (prepareImageWithin)
import Max.Media.Rendition (rawVideoAttachment, videoRendition)
import Max.Media.Vision (VideoAttachment (..), blockVisionTokens, wholeVideo)
import Max.ModelCatalog (ContextLimits (..), VisionLimits (..))
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
import Max.Prompt.History (HistorySelection (..), collectHistory)
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
        prLimits,
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
import Max.Time (fmtHM)
import Max.Turn.Continuity (renderRecentTurn)

-- | Shared read-only collection for ordinary prompts and diagnostic previews.
collectContextPreview ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  PromptRequest -> Eff es ContextSnapshot
collectContextPreview request = do
  now <- liftIO getCurrentTime
  history <- collectHistory request
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
  let compartments' = history.selectedCompartments
      transcript' = history.selectedHistory
  pinnedItems' <- fetchMessagesByIdsInScope scope s.pinned
  -- Bound the uncached memory block; older entries remain searchable.
  let memoryCap = memoryInjectCap request.prLimits request.prMultimodal
  groupMems <- listRecentMemories (groupMemoryNamespace scope) memoryCap
  userMems <- listRecentMemories (userMemoryNamespace scope senderPrincipal) memoryCap
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
  -- Media captions retain canonical handles for later tool lookup.
  mediaSegs <- fetchMediaSegments ctxIds
  let enrich = tagMediaMarkers mediaSegs . applyStickerCaptions capMap
      transcript'' = map enrich transcript'
      pinnedItems'' = map enrich pinnedItems'
      replyCtx' = fmap (\(r, f, kids) -> (enrich r, f, map enrich kids)) replyCtx0
      replyItems = maybe [] (\(r, _, kids) -> r : kids) replyCtx'
  -- Inline trigger, reply-target and pinned images; ambient images remain handles.
  let transcriptCtx
        | multimodal' =
            let inlineIds =
                  Set.fromList (mid : map (.canonicalId) (replyItems <> pinnedItems''))
             in [ if h.canonicalId `Set.member` inlineIds then h else tagImageMarkers mediaSegs h
                | h <- transcript''
                ]
        | otherwise = transcript''
  -- Forwarded triggers may still be downloading; wait before expanding children.
  triggerKids <-
    if any isForwardNode gm.body.nodes
      then do
        waitForTriggerForward mid
        -- Same enrichment as every other rendered line — in
        -- particular nested forwards must carry their [forward#<id>]
        -- handle so the model can context_read a forward ref one level deeper.
        map enrich <$> fetchForwardChildrenInScope scope mid maxForwardLines
      else pure []
  -- Trigger/reply videos take the vision budget first: they are what the
  -- user points at, and each is a whole item. Ambient videos remain handles
  -- for view_video. Display order stays images, then videos.
  let vision = request.prLimits.visionLimits
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
        loadPromptVideos vision cands
      else pure []
  images' <-
    if multimodal'
      then do
        -- Wait only for newly queued trigger images, not older context downloads.
        let expected = downloadableImageCount gm.body
        when (expected > 0) $ waitForTriggerImages mid expected
        -- Budget priority: the reply target is what the user is
        -- pointing at, then pins (explicit user signals).  Ambient
        -- recency is deliberately NOT a candidate any more — see the
        -- marker-tagging pass above.
        loadPromptImages
          vision
          (maybe maxBound (\limits -> limits.requestTokens - sum (mapMaybe (.piVisionTokens) videos')) vision)
          tz'
          mid
          (Set.fromList (map (.canonicalId) replyItems))
          (dedupById (replyItems <> pinnedItems''))
      else pure []
  pure $
    ContextSnapshot
      { csInputs =
          PromptInputs
            { defaultPersona = defaultPersona,
              session = s,
              triggerMessage = gm,
              recentTurns = recentTurns',
              continuationView = continuation',
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
            }
      }

-- | Wait for downloaded trigger-image rows, up to 'waitImagesMaxMs'. Failed
-- downloads create no row, so timeout continues with whichever images arrived.
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

-- | Load the candidates' downloaded videos as prompt attachments, at most
-- 'maxPromptVideos' and, under a declared vision envelope, as cached
-- renditions within the request budget. Missing or failed videos keep their
-- [video#<id>] marker.
loadPromptVideos ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Maybe VisionLimits ->
  [(Int64, Text)] -> -- (message_id, attachment label prefix, sans colon)
  Eff es [PromptImage]
loadPromptVideos vision cands = do
  rows <- concat <$> traverse messageVideos cands
  go (maybe maxBound (.requestTokens) vision) (take maxPromptVideos rows)
  where
    messageVideos (mid, label) = do
      rows <-
        query
          "SELECT v.mime_type, v.sha256, v.duration_seconds \
          \  FROM message_videos mv \
          \  JOIN videos v USING (sha256) \
          \  WHERE mv.canonical_message_id = ? \
          \  ORDER BY mv.seg_index"
          (Only mid)
      pure [(label, row) | row <- rows :: [(Text, Text, Maybe Double)]]
    go _ [] = pure []
    go left ((label, (mime, sha, mDur)) : rest) = case blobRefFromSha256 sha of
      Nothing -> do
        logAttention "prompt: invalid video blob ref" $ object ["sha256" .= sha]
        go left rest
      Just ref -> case vision of
        -- The probed duration goes into the label: the model's own
        -- duration perception from sampled frames is unreliable (a 29s
        -- clip once read back as "2.1秒").
        Nothing ->
          try @IOException (readBlob ref) >>= \case
            Left e -> do
              logAttention "prompt: video read failed" $ object ["sha256" .= sha, "error" .= T.pack (show e)]
              go left rest
            Right bytes -> (attached (rawVideoAttachment mime mDur bytes) :) <$> go left rest
        Just limits -> do
          rendered <- videoRendition limits wholeVideo sha (either (Left . T.pack . show) Right <$> try @IOException (readBlob ref))
          case rendered of
            Right video
              | Just tokens <- video.attachmentTokens,
                tokens <= left ->
                  (attached video :) <$> go (left - tokens) rest
            _ -> go left rest
      where
        attached video = PromptImage (label <> video.attachmentNote <> ":") video.attachmentDataUrl video.attachmentTokens

-- | Wait up to 'waitForwardMaxMs' for forwarded children; otherwise retain the
-- bare marker. Children from one fetch are committed together.
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

-- | Unbanned sticker handles and captions, in segment order for each message.
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

-- | Maximum attachments per prompt, with the trigger taking priority.
maxPromptImages :: Int
maxPromptImages = 8

-- | Skip larger image files, retaining their text markers. Providers may impose
-- a lower limit; this is the local file-size bound before base64 encoding.
maxImageBytes :: Int
maxImageBytes = 20 * 1024 * 1024

-- | Allocate image slots to the trigger first, then candidates in priority
-- order, within the remaining vision budget. Display context chronologically
-- with the trigger last; skip missing/oversized files.
loadPromptImages ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Maybe VisionLimits ->
  Int -> -- vision tokens left for images
  TimeZone -> -- display timezone for the image labels' HH:MM
  Int64 -> -- trigger canonical message id
  Set.Set Int64 -> -- canonical ids belonging to the quoted reply (incl. forward children)
  [HistoryItem] -> -- context candidates, priority order, deduped
  Eff es [PromptImage]
loadPromptImages vision budget tz' mid replyIds candidates = do
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
  loaded <- allocate budget picked
  let (trigImgs, contextUnsorted) = partitionEithers loaded
      ctxImgs = map snd (sortOn fst contextUnsorted)
  pure (ctxImgs <> trigImgs)
  where
    allocate _ [] = pure []
    allocate left (candidate : rest) = do
      loaded <- either (loadOne "[current message] 里的图片:") (uncurry loadCtx) candidate
      case loaded of
        Just (image, tokens)
          | tokens <= left ->
              (either (const (Left image)) (\(h, _) -> Right (h.receivedAt, image)) candidate :) <$> allocate (left - tokens) rest
        _ -> allocate left rest
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
        pure Nothing
      Just ref -> do
        eres <- try @IOException (readBlob ref)
        case eres of
          Right bytes0 -> do
            (mime', bytes) <- liftIO (prepareImageWithin vision mime bytes0)
            if BS.length bytes > maxImageBytes
              then do
                logAttention "prompt: image skipped (too large)" $
                  object ["sha256" .= sha, "bytes" .= BS.length bytes]
                pure Nothing
              else
                let b64 = TE.decodeUtf8 (B64.encode bytes)
                    image = PromptImage label ("data:" <> mime' <> ";base64," <> b64) Nothing
                 in pure (Just (image, maybe 0 (\limits -> blockVisionTokens limits (ImageDataUrl image.piDataUrl)) vision))
          Left e -> do
            logAttention "prompt: image read failed" $
              object ["sha256" .= sha, "error" .= T.pack (show e)]
            pure Nothing
