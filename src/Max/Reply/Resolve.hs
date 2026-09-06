-- | Shared model-text to canonical IR resolution. No publication or transport.
module Max.Reply.Resolve
  ( ResolveContext (..),
    prepareReplyChunk,
    resolveModelText,
    cleanModelText,
    stripStickerText,
    stripBareMarkers,
    stripThinkSpans,
    messageImageNodes,
  )
where

import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.Char (isDigit)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope, conversationScopeFor)
import Max.DB.History (fetchMessageInScope)
import Max.DB.Media (StoredImage (..), fetchMessageImagesInScope)
import Max.DB.Stickers (findStickerByCaption)
import Max.Effects.Blob (Blob, blobRefSha256, putBlob)
import Max.IR
import Max.IR.Digest (digest)
import Max.IR.Prompt (MentionRoster (..), parseModelChunk)
import Max.Platform.Store (resolveMentionIdentities)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId)
import Max.Render (renderCodeImage, renderTableImage)
import Max.Reply
  ( Chunk (..),
    CodeBlock (..),
    stripHallucinatedTokens,
  )
import Max.Sticker (ResolvedSticker (..), resolveSticker)
import OneBot.Types (GroupId (..), isPrivateChat)

-- | Where a reply is going and what it may do when it gets there.
-- Everything here is fixed for the duration of one dispatch.
data ResolveContext = ResolveContext
  { rtGroupId :: !GroupId,
    -- | Display-name → principal, so @\@显示名@ can be rescued into the
    -- canonical @[\@#id]@ form small models keep forgetting to write.
    -- This is the roster the prompt actually showed, so the names the model
    -- may write are exactly the names it was given.
    rtRosterNames :: ![(T.Text, PrincipalId)],
    -- | The bot's own principal, so a self-mention the model copied out of
    -- the transcript is dropped instead of sent.
    rtSelfPrincipal :: !(Maybe PrincipalId),
    -- | Whether sticker sending is enabled for this group.
    rtStickers :: !Bool,
    -- | Portable endpoint gates.  The prompt is the friendly policy; these
    -- are the fail-closed execution boundary for hallucinated/old tokens.
    rtCanReply :: !Bool,
    rtCanMention :: !Bool,
    rtCanFace :: !Bool,
    rtCanImage :: !Bool
  }

-- | Resolve model placeholders before publication. Canned reminders use the
-- same resolver, then commit one message with their unique fire provenance.
prepareReplyChunk ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ResolveContext ->
  Set (Int64, Maybe Int) ->
  Chunk ->
  Eff es (Set (Int64, Maybe Int), Maybe (Body 'Canonical, Maybe CanonicalMessageId, T.Text))
prepareReplyChunk rt = planChunk
  where
    -- One chunk becomes one ingest-phase body plus an envelope reply.
    -- Model-only handles are resolved before publication, and image handles
    -- are deduplicated across the complete streamed reply.
    planChunk b (TableChunk src) =
      renderedChunk b "table" "table.png" src src (renderTableImage src)
    planChunk b (CodeChunk cb) =
      -- The picture is what an image endpoint gets; @cbBody@ is what one
      -- without gets, and the fences come off on the way — they are
      -- markdown, and a platform that cannot render the image cannot
      -- render them either.
      renderedChunk b "code" "code.png" cb.cbSource cb.cbBody (renderCodeImage cb.cbLang cb.cbBody)
    planChunk b (TextChunk t) = do
      (b', reply, body) <- resolveModelText rt b t
      pure (b', if null body.nodes then Nothing else Just (body, reply, t))

    -- Render source to a picture and carry both texts on the node: the
    -- source so the model reads back what it wrote, and the fold text so a
    -- text-only endpoint — or one whose media budget is already spent —
    -- receives the content rather than "[图片: code.png]".
    renderedChunk b subject fileName promptText foldText render = do
      rendered <- liftIO render
      let asText = pure (b, Just (Body [NText foldText], Nothing, foldText))
      case rendered of
        Right png -> do
          blob <- putBlob png
          case mediaBlobRef (blobRefSha256 blob) of
            Nothing -> do
              logAttention (subject <> " render produced an invalid blob reference") $ object []
              asText
            Just source ->
              pure
                ( b,
                  Just
                    ( Body
                        [ NMedia
                            (Just source)
                            MediaMeta
                              { kind = MImage,
                                mime = Just "image/png",
                                sizeBytes = Just (fromIntegral (BS.length png)),
                                name = Just fileName,
                                description = Nothing,
                                raw =
                                  Just
                                    ( object
                                        [ "prompt_text" .= promptText,
                                          "fold_text" .= foldText
                                        ]
                                    )
                              }
                        ],
                      Nothing,
                      promptText
                    )
                )
        Left err -> do
          logAttention (subject <> " render failed, sending text") $ object ["error" .= err]
          asText

dedupeModelImages ::
  Set (Int64, Maybe Int) -> Body 'ModelParsed -> (Set (Int64, Maybe Int), Body 'ModelParsed)
dedupeModelImages seen0 body =
  let (seen, kept) = foldl' step (seen0, []) body.nodes
   in (seen, Body (reverse kept))
  where
    step (seen, kept) node = case node of
      NMedia (RefImage (CanonicalMessageId messageId) seg) _
        | Set.member (messageId, seg) seen || Set.member (messageId, Nothing) seen -> (seen, kept)
        | otherwise -> (Set.insert (messageId, seg) seen, node : kept)
      _ -> (seen, node : kept)

-- | Everything model text must lose before it can become visible.  Kept in
-- the same module as sending so streamed final text, progress narration, and
-- the final remainder cannot drift into subtly different grammars.
cleanModelText :: T.Text -> T.Text
cleanModelText = T.strip . stripBareMarkers . stripStickerText . stripHallucinatedTokens . stripThinkSpans

-- | Drop inline reasoning.  Models that inline their chain of thought
-- (MiniMax, GLM, …) open with @\<think\>@ instead of filling a reasoning
-- field; 'Max.Effects.LLM.stripLeadingThink' removes it at the source.
--
-- This is here /as well/ because the source-side strip was present, deployed
-- and passing its own tests when production leaked a full monologue to a group
-- twice — 2026-08-13 and 2026-08-15, both minimax-m3, both streamed, four
-- paragraphs of reasoning sent as chat while the block was still open.  The
-- interior was audited line by line and the leak was not found in it.  So the
-- guarantee is moved to where it cannot be bypassed: this function is the last
-- thing model text passes through before it becomes a message, and its own
-- contract already says so.
--
-- An unclosed block takes everything after it.  A half-arrived monologue is
-- never the answer, and the two failure directions are not symmetric: holding
-- text costs latency, releasing it cannot be undone.
stripThinkSpans :: T.Text -> T.Text
stripThinkSpans t = case T.breakOn opener t of
  (_, rest) | T.null rest -> t
  (before, rest) -> case T.breakOn closer (T.drop (T.length opener) rest) of
    (_, after)
      | Just remainder <- T.stripPrefix closer after -> before <> stripThinkSpans remainder
      | otherwise -> before
  where
    opener = "<think>"
    closer = "</think>"

-- | Drop bare display markers echoed from transcript context.  Id-carrying
-- send tokens remain intact for 'sendAndPersistReply' to resolve.
stripBareMarkers :: T.Text -> T.Text
stripBareMarkers t =
  foldl'
    (\acc marker -> T.replace marker "" acc)
    t
    ["[image]", "[sticker]", "[动画表情]", "[mface]", "[face]", "[forward]"]

-- | Drop hallucinated sticker-caption display spans while preserving the
-- real @[sticker#id]@ / legacy @[表情包#id]@ send forms.
stripStickerText :: T.Text -> T.Text
stripStickerText t0 = foldl' stripOpener t0 ["[sticker:", "[sticker：", "[表情包"]
  where
    stripOpener t1 opener = go t1
      where
        go t = case T.breakOn opener t of
          (before, rest)
            | T.null rest -> t
            | otherwise ->
                let afterOpener = T.drop (T.length opener) rest
                 in if isSendToken afterOpener
                      then before <> opener <> go afterOpener
                      else case T.breakOn "]" afterOpener of
                        (_, close)
                          | T.null close -> before
                          | otherwise -> before <> go (T.drop 1 close)
    isSendToken s = case T.uncons s of
      Just ('#', r) -> maybe False (isDigit . fst) (T.uncons r)
      _ -> False

-- | Resolve model text once for replies, reminders and artifact captions.
resolveModelText ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  ResolveContext ->
  Set (Int64, Maybe Int) ->
  T.Text ->
  Eff es (Set (Int64, Maybe Int), Maybe CanonicalMessageId, Body 'Canonical)
resolveModelText rt b raw = do
  let t = cleanModelText raw
  let (mReplyId, parsed0) = parseModelChunk mentionRoster t
      (seen', parsed) = dedupeModelImages b parsed0
      b' = seen'
  mentions <-
    if rt.rtCanMention && not (isPrivateChat rt.rtGroupId)
      then resolveMentionIdentities conversationId [p | NMention p _ <- parsed.nodes]
      else pure Map.empty
  logInfo "model chunk parsed" $ object ["content" .= digest parsed0]
  mReplyId' <- case mReplyId of
    _ | not rt.rtCanReply -> pure Nothing
    Nothing -> pure Nothing
    Just rid ->
      fetchMessageInScope conversation rid >>= \case
        Just _ -> pure (Just rid)
        Nothing -> do
          logAttention "reply placeholder outside conversation" $
            object ["message_id" .= rid]
          pure Nothing
  resolved <- concat <$> traverse (resolveModelNode mentions) parsed.nodes
  let content = trimEdges (mergeText resolved)
  pure (b', CanonicalMessageId <$> mReplyId', Body content)
  where
    mentionRoster = MentionRoster {names = rt.rtRosterNames, selfPrincipal = rt.rtSelfPrincipal}

    resolveModelNode mentions = \case
      NText text -> pure [NText text]
      NMention principal display -> case Map.lookup principal mentions of
        Just identity -> pure [NMention (MentionIdentity identity) display]
        Nothing -> pure [NText (mentionToken display)]
      NEmote emote
        | rt.rtCanFace -> pure [NEmote emote]
        | otherwise -> pure []
      NMedia ref _ -> resolveModelMedia ref
      NCard card -> pure [NCard card]

    resolveModelMedia = \case
      RefSticker _ | not rt.rtStickers -> pure []
      RefStickerDesc _ | not rt.rtStickers -> pure []
      RefStickerDesc caption ->
        findStickerByCaption caption >>= \case
          Just stickerId -> resolveModelMedia (RefSticker stickerId)
          Nothing -> do
            logAttention "sticker caption unresolved" $ object ["caption" .= caption]
            pure []
      RefSticker stickerId ->
        resolveSticker stickerId >>= \case
          Right sticker -> pure [sticker.node]
          Left err -> do
            logAttention "sticker placeholder unresolved" $
              object ["id" .= stickerId, "error" .= err]
            pure []
      RefImage _ _ | not rt.rtCanImage -> pure []
      RefImage (CanonicalMessageId messageId) seg -> do
        images <- messageImageNodes conversation messageId seg
        when (null images) $
          logAttention "image placeholder unresolved" $
            object ["canonical_message_id" .= messageId, "seg_index" .= seg]
        pure images

    conversation = conversationScopeFor rt.rtGroupId
    GroupId conversationId = rt.rtGroupId

-- | Resolve a model-authored image handle to canonical blob-backed nodes.
-- The delivery worker owns blob loading and permanent-failure policy; the
-- publication path records only content addresses and never re-encodes bytes.
messageImageNodes ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  ConversationScope ->
  Int64 ->
  Maybe Int ->
  Eff es [Node 'Canonical]
messageImageNodes scope mid seg = do
  rows <- fetchMessageImagesInScope scope mid seg
  fmap concat . traverse node $ rows
  where
    node image = case mediaBlobRef image.storedImageSha256 of
      Nothing -> do
        logAttention "image resend: invalid blob ref" $ object ["sha256" .= image.storedImageSha256]
        pure []
      Just source ->
        pure
          [ NMedia
              (Just source)
              MediaMeta
                { kind = MImage,
                  mime = Just image.storedImageMime,
                  sizeBytes = Nothing,
                  name = Nothing,
                  description = Nothing,
                  -- The handle this picture is known by, carried so the
                  -- resend's own transcript line names the same picture the
                  -- model pointed at rather than a bare [image] marker.
                  raw =
                    Just
                      ( object
                          [ "source_message_id" .= mid,
                            "source_seg_index" .= image.storedImageSegIndex
                          ]
                      )
                }
          ]
