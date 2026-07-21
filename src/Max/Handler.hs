module Max.Handler
  ( handleEvents,
    dispatchProactive,
    stripStickerText,
    stripBareMarkers,
    isSilentReply,
    parseSilence,
  )
where

import Control.Concurrent.STM (TQueue, atomically, newTVarIO, readTQueue)
import Control.Monad (foldM_, unless, void, when)
import Data.Aeson (Value, withObject, (.:))
import Data.Foldable (for_)
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Char (isDigit)
import Data.Int (Int64)
import Control.Applicative ((<|>))
import Data.List (find)
import Data.Maybe (isJust, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Concurrent.Async (Concurrent, async)
import Effectful.Exception (SomeException, catch, finally)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
import System.FilePath ((</>))
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Command.Dispatcher qualified as CmdDispatch
import Max.Command.Dispatcher (DispatchResult (..))
import Max.Command.Parser (parseCommand)
import Max.DB.History (HistoryItem (..), fetchMessage, fetchRecentInGroup)
import Max.DB.Message (insertGroupMessage, insertOutbound)
import Max.Effects.Agent (Agent, AgentResult (..), DispatchContext (..), agentTurn)
import Max.Effects.LLM (LLM, isProfileMultimodal)
import Max.Effects.NapCat (NapCat, callAction, sendAction)
import Max.Env (BotEnv (..))
import Max.Files (FileQueue, enqueueFiles)
import Max.MemoryExtract (extractMemories)
import Max.Forward (ForwardQueue, enqueueForwards)
import Max.Images (ImageQueue, enqueueImages)
import Max.Intent (IntentConfig (..), IntentState, classifySupplement, clearPendingIntent, enqueueIntent)
import Max.Persistence (PersistMode, isEphemeral, withEphemeral)
import Max.Prompt (TriggerOrigin (..), buildContext, renderCurrentLine, renderHistoryLine)
import Max.Roster (GroupMember (..), fetchGroupMembers, fetchGroupMeta, memberName, renderGroupBrief)
import Max.Session (Session (..), loadSession, readSession)
import Max.Tasks (TaskCancelled (..), listTasks, pushBtwToLatest)
import Max.Render (renderTableImage)
import Max.Reply (Chunk (..), ReplyPiece (..), dedupeImagePieces, parseReplyTokens, planReply)
import Max.Sticker (resolveSticker)
import Max.Util (catchSync, trySync)
import OneBot.Action (Action (..), Response (..), sendChatMsg)
import OneBot.Event (Event (..), GroupMessage (..), PokeEvent (..), Sender (..))
import OneBot.Segment (Segment (..), imageSeg, mentionsUser, renderPlainText, segmentMentions)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)

-- | Decision derived from one group message.
data Trigger
  = -- | Bot was not addressed and message is not a command; do nothing.
    TriggerNone
  | -- | @\@bot ping@ — fast path, no LLM.
    TriggerPong
  | -- | @\@bot ...@ with any other body. Carries the user-facing body
    -- with the @bot mention already stripped.
    TriggerLLM !T.Text
  | -- | Message is a @!@-command (with or without @-mention).  Dispatch
    -- through 'Max.Command.Dispatcher'; no LLM.
    TriggerCommand !T.Text
  | -- | Malformed command (starts with @!ident@ but parser failed).
    -- Surface the error back to the user.
    TriggerCommandError !T.Text
  deriving stock (Show)

-- | @repliesToBot@ = the message quotes (replies to) one of the
-- bot's own messages; the caller resolves that via DB lookup.  A
-- reply to the bot counts as addressing it, same as an @-mention.
-- In a private chat every message addresses the bot.
classify :: Bool -> GroupMessage -> Trigger
classify repliesToBot gm =
  let raw = T.strip (renderPlainText gm.message)
      stripped = T.strip (stripMentions gm.selfId raw)
      addressed =
        mentionsUser gm.selfId gm.message
          || repliesToBot
          || isPrivateChat gm.groupId
   in case parseCommand stripped of
        Right (Just _) -> TriggerCommand stripped
        Left err -> TriggerCommandError err
        Right Nothing
          | not addressed -> TriggerNone
          | otherwise -> case stripped of
              "ping" -> TriggerPong
              -- A bare @bot (or bare reply) still triggers — the
              -- model sees the ambient/reply context and reacts.
              _ -> TriggerLLM stripped

-- | App-lived event loop. Persists every group message, enqueues image
-- and forward jobs, dispatches @\@bot@ traffic. DB and dispatch failures
-- are logged but never tear down the loop.
handleEvents ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  TQueue Event ->
  ImageQueue ->
  ForwardQueue ->
  FileQueue ->
  Maybe IntentState -> -- proactive-trigger buffers ('Nothing' = feature off)
  Eff es ()
handleEvents q imgQ fwdQ fileQ mIntent = loop
  where
    loop = do
      ev <- liftIO (atomically (readTQueue q))
      case ev of
        EvHeartbeat -> pure ()
        EvLifecycle sub ->
          logInfo "lifecycle" $ object ["sub_type" .= sub]
        EvRaw v ->
          logTrace "unhandled event" v
        EvGroupMessage gm -> do
          persist gm
          liftIO (enqueueImages imgQ gm)
          liftIO (enqueueForwards fwdQ gm)
          enqueueFiles fileQ gm
          onGroupMessage mIntent gm
        EvPoke pk -> onPoke mIntent pk
      loop

persist :: (Log :> es, WithConnection :> es, IOE :> es) => GroupMessage -> Eff es ()
persist gm =
  trySync (insertGroupMessage gm) >>= \case
    Right () -> pure ()
    Left e ->
      logAttention "db insert failed" $
        object ["error" .= T.pack (show e)]

onGroupMessage ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  Maybe IntentState ->
  GroupMessage ->
  Eff es ()
onGroupMessage mIntent gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
  logInfo "group message" $
    object
      [ "group_id" .= gidRaw,
        "user_id" .= fromRaw,
        "text" .= renderPlainText gm.message
      ]
  -- Cheap pure pass first; only when it says "not addressed" AND the
  -- message quotes something do we pay a PK lookup to see whether
  -- the quoted message was ours (reply-to-bot counts as addressing).
  trig <- case classify False gm of
    TriggerNone
      | Just rid <- listToMaybe [m | SegReply (MessageId m) <- gm.message] -> do
          mQuoted <- fetchMessage rid
          let UserId selfRaw = gm.selfId
          pure $ case mQuoted of
            Just quoted | quoted.userId == selfRaw -> classify True gm
            _ -> TriggerNone
    t -> pure t
  -- A direct trigger clears the group's pending intent buffer: those
  -- messages reach the model as ambient context of this turn, and
  -- must not also produce a second, proactive reply.
  let clearIntent = for_ mIntent $ \st -> liftIO (clearPendingIntent st gm.groupId)
  case trig of
    -- Not addressed: hand the message to the intent classifier —
    -- maybe the bot wants to join in anyway.
    TriggerNone -> for_ mIntent $ \st -> liftIO (enqueueIntent st gm)
    TriggerPong -> clearIntent >> sendPong gm
    TriggerCommand body -> clearIntent >> dispatchCommand gm body
    TriggerCommandError err -> replyText gm ("命令解析失败:\n" <> err)
    TriggerLLM _ -> clearIntent >> dispatchLLM OriginDirect gm

-- | A 戳一戳 aimed at the bot: a contentless direct wake, the soft
-- version of an @.  If the group already has a running task the poke
-- reads as a nudge and goes into its btw inbox; otherwise it starts a
-- normal dispatch with 'OriginPoke' so the prompt says honestly who
-- poked (and that there is no message).  Pokes between other members,
-- and echoes of the bot's own outbound pokes, are ignored.
onPoke ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  Maybe IntentState ->
  PokeEvent ->
  Eff es ()
onPoke mIntent pk
  | pk.pkTargetId /= pk.pkSelfId || pk.pkUserId == pk.pkSelfId = pure ()
  | otherwise = do
      env :: BotEnv <- ask
      let GroupId gidRaw = pk.pkGroupId
          UserId pokerRaw = pk.pkUserId
      logInfo "poked" $ object ["group_id" .= gidRaw, "user_id" .= pokerRaw]
      -- Same as a direct trigger: the poke supersedes any pending
      -- proactive classification for this group.
      for_ mIntent $ \st -> liftIO (clearPendingIntent st pk.pkGroupId)
      -- Best-effort display name for the poker (groups only; the
      -- private-chat peer needs no introduction).
      mName <-
        if isPrivateChat pk.pkGroupId
          then pure Nothing
          else do
            members <- fetchGroupMembers pk.pkGroupId
            pure (memberName <$> (find (\m -> m.mUserId == pk.pkUserId) =<< members))
      let pokerName = maybe (T.pack (show pokerRaw)) id mName
      injected <-
        liftIO (pushBtwToLatest env.beTasks pk.pkGroupId (pokerName <> " 戳了戳你"))
      if injected
        then
          logInfo "poke: injected into running task" $
            object ["group_id" .= gidRaw]
        else dispatchLLM OriginPoke (pokeTrigger pk mName)

-- | Synthesize the trigger 'GroupMessage' for a poke dispatch.  There
-- is no real message: id 0 is the "no trigger message" sentinel
-- (nothing quotes or reacts to it — see 'Max.Tools.sayTool') and the
-- segment list is empty ('OriginPoke' rendering never shows it).
pokeTrigger :: PokeEvent -> Maybe T.Text -> GroupMessage
pokeTrigger pk mName =
  GroupMessage
    { selfId = pk.pkSelfId,
      groupId = pk.pkGroupId,
      userId = pk.pkUserId,
      messageId = MessageId 0,
      message = [],
      rawMessage = "",
      sender = Sender pk.pkUserId mName Nothing
    }

--------------------------------------------------------------------------------
-- Commands.

dispatchCommand ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  GroupMessage ->
  T.Text ->
  Eff es ()
dispatchCommand gm body = localDomain "cmd" $ do
  case parseCommand body of
    Left err -> replyText gm ("命令解析失败:\n" <> err)
    Right Nothing -> pure () -- shouldn't reach here; classify already filtered
    Right (Just cmd) -> do
      env :: BotEnv <- ask
      t <- loadSession env.beSessions env.beDefaultModel gm.groupId
      logInfo "command" $ object ["cmd" .= T.pack (show cmd)]
      let replyTarget = listToMaybe [m | SegReply (MessageId m) <- gm.message]
      result <- CmdDispatch.execute t gm.groupId gm.userId replyTarget cmd
      case result of
        ReplyText reply -> replyText gm reply
        EphemeralAsk askBody -> do
          logInfo "btw: ephemeral dispatch" $
            object ["len" .= T.length askBody]
          -- Rebuild the trigger with the !btw body as the user
          -- message; preserve everything else (reply target, sender,
          -- self id) so buildContext sees a normal @-mention.
          let virtualGm =
                gm
                  { message =
                      [ SegAt gm.selfId,
                        SegText (" " <> askBody)
                      ]
                  }
          withEphemeral $ dispatchLLM OriginDirect virtualGm

--------------------------------------------------------------------------------
-- LLM dispatch.

sendPong :: (NapCat :> es, Log :> es) => GroupMessage -> Eff es ()
sendPong gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
  sendAction (sendChatMsg gm.groupId (replySegs gm " pong"))
  logInfo "replied pong" $ object ["to" .= fromRaw, "group_id" .= gidRaw]

-- | Reply segments for a trigger: quote it, @-the sender (groups
-- only — a private chat has no third party to disambiguate for, and
-- NapCat renders private at-segments poorly), then the text.
replySegs :: GroupMessage -> T.Text -> [Segment]
replySegs gm body =
  [SegReply gm.messageId]
    <> [SegAt gm.userId | not (isPrivateChat gm.groupId)]
    <> [SegText body]

-- | Entry point for the intent worker: dispatch a message nobody
-- @-ed at the bot, with the prompt honestly labelled as a proactive
-- turn (and @[silence]@ explicitly on the table).
dispatchProactive ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  GroupMessage ->
  Eff es ()
dispatchProactive = dispatchLLM OriginProactive

-- | Spawn an async to build the prompt, call the LLM, post the reply,
-- and append the (user, assistant) turn to the session history.
-- The 'TriggerOrigin' says what woke the bot — see
-- 'Max.Prompt.PromptInputs.origin'.
dispatchLLM ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader PersistMode :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  TriggerOrigin ->
  GroupMessage ->
  Eff es ()
dispatchLLM origin gm = void $ async $
  localDomain "llm" $ do
    let UserId fromRaw = gm.userId
        GroupId gidRaw = gm.groupId
        MessageId midRaw = gm.messageId
    logInfo "llm dispatch" $
      object
        [ "group_id" .= gidRaw,
          "user_id" .= fromRaw,
          "message_id" .= midRaw,
          "origin" .= T.pack (show origin)
        ]
    -- 'TaskCancelled' is async-tagged, so it flies past 'catchSync'
    -- (and every trySyncIO on the way up) — the outer 'catch' is the
    -- one place a user-initiated @!kill@ comes to rest.
    ( work `catchSync` \e ->
        logAttention "llm dispatch crashed" $
          object ["error" .= T.pack (show (e :: SomeException))]
      )
      `catch` \TaskCancelled ->
        -- User-initiated !kill — quieter log, not an error.
        logInfo "llm dispatch cancelled" $
          object ["group_id" .= gidRaw]
  where
    work = do
      env :: BotEnv <- ask
      t <- loadSession env.beSessions env.beDefaultModel gm.groupId
      s <- liftIO (readSession t)
      injected <- tryInjectSupplement env s
      unless injected (withProcessingReaction (dispatch env s))

    -- React [托腮] on the trigger while the dispatch runs — a quiet
    -- "seen, working on it" — and clear it once the reply (or
    -- silence / crash / !kill) lands.  Fire-and-forget both ways: a
    -- failed reaction must never affect the dispatch.  Proactive
    -- turns skip it — nobody addressed the bot, and a reaction
    -- appearing on random chatter (then vanishing on [silence])
    -- would leak that the bot was weighing in.
    withProcessingReaction act
      | origin /= OriginDirect = act
      | otherwise =
          (sendAction (SetMsgEmojiLike gm.messageId processingFaceId True) >> act)
            `finally` sendAction (SetMsgEmojiLike gm.messageId processingFaceId False)

    -- Implicit !btw: when the group already has a running task, a
    -- fresh @-trigger is often steering that task（追加要求、修正
    -- 方向、催进度）rather than starting something new.  Ask the
    -- intent profile which it is; a supplement goes into the running
    -- task's inbox — the task's eventual reply addresses it — instead
    -- of spawning a parallel dispatch.  Gated on intent being
    -- configured; proactive and ephemeral turns never reroute.  Any
    -- doubt (classifier says no, errors out, or the task finished
    -- while we were classifying) falls back to a normal dispatch.
    tryInjectSupplement env s = do
      ephemeral <- isEphemeral
      case env.beIntent of
        Just icfg | origin == OriginDirect && not ephemeral -> do
          running <- liftIO (listTasks env.beTasks (Just gm.groupId))
          if null running
            then pure False
            else do
              let GroupId gidRaw = gm.groupId
                  MessageId midRaw = gm.messageId
                  UserId selfRaw = gm.selfId
              rows <- fetchRecentInGroup gidRaw 0 s.clearedAt icfg.icContextLines
              let ctxLines =
                    map (renderHistoryLine env.beTimeZone selfRaw) $
                      filter (\h -> h.messageId /= midRaw) rows
                  newLine = renderCurrentLine gm
              isSupp <- classifySupplement icfg ctxLines newLine
              if not isSupp
                then pure False
                else do
                  ok <- liftIO (pushBtwToLatest env.beTasks gm.groupId newLine)
                  when ok $
                    logInfo "btw: implicit injection" $
                      object ["group_id" .= gidRaw, "message_id" .= midRaw]
                  pure ok
        _ -> pure False

    dispatch env s = do
      multimodal <- isProfileMultimodal s.model
      (mentionable, brief) <- fetchGroupContext gm.groupId
      ctx <- buildContext env.bePersona env.beHistoryWindow multimodal origin env.beBlobRoot env.beTimeZone brief s gm
      toolImgs <- liftIO (newTVarIO (0, []))
      let debugEff = maybe env.beDebugDefault id s.debugOverride
          stickersEff = maybe env.beStickerDefault id s.stickerOverride
          dc = DispatchContext gm.groupId gm.messageId gm.userId gm.selfId debugEff multimodal stickersEff mentionable toolImgs
      result <- agentTurn dc s.model s.thinkingOverride ctx
      case result.reply of
        -- The loop produced no model-authored reply — upstream API
        -- down, or the turn-cap fallback call failed too.  Error text
        -- in the group would just be noise; swap the processing
        -- reaction for a NO (face 123) so the trigger visibly failed.
        -- Nothing is drained or persisted, same as a silent turn.
        Nothing -> do
          logAttention "llm dispatch failed" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "turns" .= result.turnsUsed,
                "aborted" .= result.aborted
              ]
          when (origin == OriginDirect) $ do
            sendAction (SetMsgEmojiLike gm.messageId processingFaceId False)
            sendAction (SetMsgEmojiLike gm.messageId failureFaceId True)
        Just replyRaw -> handleReply env s mentionable ctx result replyRaw

    handleReply env s mentionable ctx result replyRaw = do
      -- Real stickers/images are the [sticker#<id>] / [image#<id>]
      -- tokens, resolved when the reply is sent.  The captionless
      -- "[表情包: …]" and bare "[image]"/"[动画表情]"/"[face]"/…
      -- forms are hallucinations — a weaker model imitating the
      -- display style of something it saw — so strip those as a
      -- backstop while leaving the id-carrying send tokens intact
      -- (see 'stripStickerText' / 'stripBareMarkers').
      let stickersEff = maybe env.beStickerDefault id s.stickerOverride
          stripped = T.strip (stripBareMarkers (stripStickerText replyRaw))
      case parseSilence stripped of
        Just mFace -> do
          -- The model opted out of replying (see 'parseSilence') —
          -- the escape hatch for turns that need no response, most
          -- importantly another bot @-ing us: answering would
          -- re-trigger it and ping-pong forever.  Nothing is sent or
          -- persisted; btw notes are NOT drained (they wait for a
          -- turn that actually delivers them); no memory extraction
          -- (a turn judged not worth answering is noise).
          --
          -- On a direct trigger the silence still shows: the named
          -- reason face (擦汗 as fallback) is reacted onto the trigger
          -- message.  Proactive turns stay traceless, and a poke has
          -- no message to react to.
          logInfo "llm chose silence" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "turns" .= result.turnsUsed,
                "face" .= mFace,
                "aborted" .= result.aborted
              ]
          when (origin == OriginDirect) $
            sendAction
              (SetMsgEmojiLike gm.messageId (maybe defaultSilenceFace id mFace) True)
        Nothing -> do
          -- callAction so we get the message_id back, then persist this
          -- outbound message into the messages table.  That's where
          -- subsequent dispatches will read this turn's assistant reply
          -- back from when reconstructing mention history.
          sendAndPersistReply gm mentionable env.beBlobRoot stickersEff stripped
          ephemeral <- isEphemeral
          logInfo "llm replied" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "len" .= T.length stripped,
                "turns" .= result.turnsUsed,
                "appended" .= length result.appended,
                "aborted" .= result.aborted
              ]
          -- Post-reply memory extraction: the user already has their
          -- answer, so this costs them nothing; ephemeral (!btw) turns
          -- must not leave traces.  A crashed extraction only logs.
          case env.beMemoryExtract of
            Just prof
              | not ephemeral ->
                  extractMemories prof env.beEmbed gm (ctx <> result.appended)
                    `catchSync` \e ->
                      logAttention "memx: crashed" $
                        object ["error" .= T.pack (show e)]
            _ -> pure ()

--------------------------------------------------------------------------------
-- Reply helper.

-- | Fire-and-forget reply (no persist).  Used for pong, command
-- responses, parse errors — chitchat we don't want polluting the
-- LLM mention history.
replyText :: NapCat :> es => GroupMessage -> T.Text -> Eff es ()
replyText gm body =
  sendAction (sendChatMsg gm.groupId (replySegs gm (" " <> body)))

-- | Send the LLM's final reply as planned by 'planReply' — one
-- message per blank-line paragraph, markdown tables rendered to a
-- PNG via typst (falling back to the markdown source when rendering
-- fails) — and persist each sent chunk into the messages table (so
-- future dispatches can read this back as mention history, and a
-- reply to *any* chunk resolves as reply-to-bot).
--
-- Outgoing placeholders are resolved per chunk ('parseReplyTokens'),
-- which is what lets the model quote a different message from each
-- paragraph and drop a sticker inline:
--
--   * a leading @[↩#\<id\>]@ becomes the chunk's 'SegReply' quote —
--     nothing is auto-quoted any more, the model decides;
--   * @[sticker#\<id\>]@ becomes a sticker segment ('resolveSticker'),
--     an unknown id is dropped rather than failing the reply;
--   * @[image#\<id\>]@ resends that message's stored images; duplicate
--     ids are dropped across the whole reply ('dedupeImagePieces') —
--     a multi-image message tags all its markers with one id, so an
--     echo would otherwise resend N images N times;
--   * @[face#\<id\>]@ becomes a QQ built-in face segment;
--   * raw @\@\<qq\>@ spans become real at-segments when the id passes
--     the membership check ('segmentMentions').
--
-- A chunk that resolves to no content (a lone @[↩#id]@, or only a bad
-- sticker token) is skipped.  Each chunk persists with its *resolved*
-- surface form as rendered_text (sticker tokens normalised to
-- @[sticker#\<id\>: \<caption\>]@, image tokens keeping their @[image#\<id\>]@
-- form, the reply token dropped — it lives in the
-- reply_to_message_id column), so what the model reads back next turn
-- matches what it wrote.  A table chunk persists with its markdown
-- source.  Consecutive bot rows are merged into one assistant turn at
-- prompt build time (see 'Max.Prompt').  Uses 'callAction' to get
-- NapCat's assigned @message_id@ per chunk; chunks are sent
-- sequentially so ordering is guaranteed.  If a send or message_id
-- extraction fails, logs and moves on.
sendAndPersistReply ::
  ( NapCat :> es,
    WithConnection :> es,
    Reader PersistMode :> es,
    Log :> es,
    IOE :> es
  ) =>
  GroupMessage ->
  Maybe (Set UserId) ->
  FilePath -> -- blob store root (for inline sticker resolution)
  Bool -> -- whether sticker sending is enabled for this group
  T.Text ->
  Eff es ()
sendAndPersistReply gm mentionable blobRoot stickersOn body = do
  -- The reply already goes out over NapCat regardless — that's a
  -- real side effect we can't undo.  Only the messages-table write
  -- is gated, so an ephemeral turn doesn't show up in the next
  -- dispatch's mention history.
  ephemeral <- isEphemeral
  foldM_
    ( \sentImgs (i, chunk) -> do
        (sentImgs', mPlan) <- planChunk sentImgs chunk
        case mPlan of
          Nothing -> pure ()
          Just (segs, rendered) ->
            callAction (sendChatMsg gm.groupId segs) 30000 >>= \case
              Left err ->
                logAttention "llm reply send failed" $ object ["error" .= err, "chunk" .= i]
              Right (Response _ rc payload _)
                | rc /= 0 ->
                    logAttention "llm reply retcode bad" $ object ["retcode" .= rc, "chunk" .= i]
                | otherwise -> case extractOutMid payload of
                    Nothing ->
                      logAttention "no message_id in send response" $
                        object ["payload" .= payload, "chunk" .= i]
                    Just outMid ->
                      unless ephemeral $
                        insertOutbound
                          gm.groupId
                          gm.selfId
                          "max"
                          (MessageId outMid)
                          (Just (T.strip rendered))
                          segs
        pure sentImgs'
    )
    Set.empty
    (zip [0 :: Int ..] (planReply body))
  where
    -- One chunk → 'Just' (segments to send, rendered_text to store) or
    -- 'Nothing' to skip; threads the set of already-resent image
    -- message ids so a duplicated [image#<id>] never resends.
    planChunk sentImgs (TableChunk src) = do
      rendered <- liftIO (renderTableImage src)
      case rendered of
        Right png ->
          pure (sentImgs, Just ([imageSeg ("base64://" <> TE.decodeASCII (B64.encode png))], src))
        Left err -> do
          logAttention "table render failed, sending source" $ object ["error" .= err]
          pure (sentImgs, Just ([SegText src], src))
    planChunk sentImgs (TextChunk t) = do
      let (mReplyId, pieces0) = parseReplyTokens t
          (sentImgs', pieces) = dedupeImagePieces sentImgs pieces0
      (content, rendered) <- resolvePieces pieces
      pure . (sentImgs',) $
        if null content
          then Nothing
          else
            let prefix = [SegReply (MessageId rid) | Just rid <- [mReplyId]]
             in Just (prefix <> content, rendered)

    -- Resolve parsed pieces into (segments, normalised rendered text).
    resolvePieces pieces = do
      parts <- traverse resolve pieces
      pure (concatMap fst parts, T.concat (map snd parts))
      where
        resolve (PieceText t) = pure (mentionSegs t, t)
        -- Sticker sending disabled for this group: drop the token
        -- (the model shouldn't emit one, but never leak it as text).
        resolve (PieceSticker _) | not stickersOn = pure ([], "")
        resolve (PieceSticker sid) =
          resolveSticker blobRoot sid >>= \case
            Right (desc, segs) ->
              pure (segs, "[sticker#" <> T.pack (show sid) <> ": " <> T.take 80 desc <> "]")
            Left err -> do
              logAttention "sticker placeholder unresolved" $
                object ["id" .= sid, "error" .= err]
              pure ([], "")
        resolve (PieceImage mid) = do
          segs <- messageImageSegs blobRoot mid
          if null segs
            then do
              logAttention "image placeholder unresolved" $ object ["message_id" .= mid]
              pure ([], "")
            else
              -- Keep the id in the persisted form: the model reads
              -- back the same [image#<id>] handle it wrote (and can
              -- resend from it again), instead of a bare [image] it
              -- was told is a hallucination.
              pure (segs, "[image#" <> T.pack (show mid) <> "]")
        resolve (PieceFace fid) =
          pure ([SegFace fid Nothing], "[face#" <> T.pack (show fid) <> "]")

    -- Private chats keep raw text: NapCat renders private
    -- at-segments poorly (see 'replySegs').  No member list (fetch
    -- failed) → convert on syntax alone rather than silently
    -- refusing to @ anyone.
    mentionSegs t
      | isPrivateChat gm.groupId = [SegText t]
      | otherwise = segmentMentions (\u -> maybe True (Set.member u) mentionable) t

-- | One roster fetch serving two prompt-side consumers: the member id
-- set for outbound @-mention validation ('Nothing' when there is no
-- meaningful list — private chat or NapCat failure — so conversion
-- falls back to syntax-only matching and a flaky API never mutes
-- legitimate @s), and the rendered 群信息 lines for the system
-- prompt's [environment] block (empty on the same failures — the model
-- just doesn't get the block).
fetchGroupContext ::
  (NapCat :> es, Log :> es) =>
  GroupId ->
  Eff es (Maybe (Set UserId), [T.Text])
fetchGroupContext gid
  | isPrivateChat gid = pure (Nothing, [])
  | otherwise = do
      members <- fetchGroupMembers gid
      meta <- fetchGroupMeta gid
      pure
        ( Set.fromList . map (.mUserId) <$> members,
          renderGroupBrief meta members
        )

extractOutMid :: Value -> Maybe Int64
extractOutMid v = case parseEither (withObject "send_resp" (\o -> o .: "message_id")) v of
  Right (mid :: Int64) -> Just mid
  Left _ -> Nothing

stripMentions :: UserId -> T.Text -> T.Text
stripMentions (UserId u) =
  T.replace ("@" <> T.pack (show u)) ""

-- | The "processing" reaction face: 托腮 (chin-on-hand, thinking).
-- Face ids come from NapCat's face_config.json (QSid).
processingFaceId :: Int
processingFaceId = 212

-- | The "request failed" reaction face: NO (the red no-gesture),
-- swapped in for 'processingFaceId' when a dispatch produced no reply.
failureFaceId :: Int
failureFaceId = 123

-- | Faces the model may name in a @[silence:<名>]@ reply to say *why*
-- it stayed silent; the face gets reacted onto the trigger message.
-- Ids from NapCat's face_config.json (QSid).
silenceFaces :: [(T.Text, Int)]
silenceFaces =
  [ ("擦汗", 97),
    ("流汗", 27),
    ("再见", 39),
    ("哈欠", 104),
    ("吃瓜", 271),
    ("困", 25),
    ("疑问", 32)
  ]

-- | Reaction used when a direct-trigger silence names no (known)
-- face: 擦汗 — the all-purpose "呃，没什么可说的".
defaultSilenceFace :: Int
defaultSilenceFace = 97

-- | Did the model opt out of replying?  The format guide tells it to
-- answer with a lone @[silence]@ — or @[silence:表情名]@ to say why —
-- when a turn calls for no response, e.g. another bot mechanically
-- @-ing us, where any answer would re-trigger it in an endless loop.
-- Expects pre-stripped input; an empty reply counts as silence too.
--
-- Returns 'Nothing' when the reply is a real answer; @Just mFace@
-- when it is silence, with the reason face (if a known one was
-- named).  Only an exact match qualifies: a reply that merely
-- *contains* the marker still goes out, so the model can't
-- accidentally mute a real answer.
parseSilence :: T.Text -> Maybe (Maybe Int)
parseSilence t
  | T.null t || t == "[silence]" || t == "[沉默]" = Just Nothing
  | Just inner <- withReason = Just (lookup (T.strip inner) silenceFaces)
  | otherwise = Nothing
  where
    withReason =
      (T.stripPrefix "[silence:" t <|> T.stripPrefix "[silence：" t)
        >>= T.stripSuffix "]"

isSilentReply :: T.Text -> Bool
isSilentReply = isJust . parseSilence

-- | Load every stored image of a message as outbound image segments
-- (base64 over @docker@-free NapCat send), for resolving a
-- @[image#\<id\>]@ resend token.  Empty when the message has no stored
-- images or a blob can't be read — the caller then drops the token
-- rather than sending a broken message.
messageImageSegs ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  FilePath ->
  Int64 ->
  Eff es [Segment]
messageImageSegs blobRoot mid = do
  rows <-
    query
      "SELECT i.local_path \
      \  FROM message_images mi \
      \  JOIN images i ON i.sha256 = mi.sha256 \
      \  WHERE mi.message_id = ? \
      \  ORDER BY mi.seg_index"
      (Only mid)
  fmap concat . traverse loadOne $ (rows :: [Only T.Text])
  where
    loadOne (Only path) =
      trySync (liftIO (BS.readFile (blobRoot </> T.unpack path))) >>= \case
        Left e -> do
          logAttention "image resend: blob read failed" $
            object ["path" .= path, "error" .= T.pack (show (e :: SomeException))]
          pure []
        Right bytes ->
          pure [imageSeg ("base64://" <> TE.decodeUtf8 (B64.encode bytes))]

-- | Drop bare display markers the model echoed from context —
-- @[image]@, @[sticker]@, @[mface]@, @[face]@, @[forward]@, plus the
-- pre-rename @[动画表情]@ still present in old rows.  None of them
-- carries an id, so echoing one can only produce literal marker text
-- in the outgoing message.  The id-carrying send tokens
-- (@[image#\<id\>]@, @[face#\<id\>]@, …) are left intact because they
-- aren't literal matches for any of these.
stripBareMarkers :: T.Text -> T.Text
stripBareMarkers t =
  foldl' (\acc m -> T.replace m "" acc) t
    ["[image]", "[sticker]", "[动画表情]", "[mface]", "[face]", "[forward]"]

-- | Remove any "[sticker: …]" / "[表情包…]" spans a model hallucinated
-- into its reply text (see call site) — the caption *display* form,
-- in either the current or the pre-rename opener.  The real send
-- token "[sticker#\<id\>…]" is left intact: it's the placeholder the
-- reply post-processor turns into an actual sticker
-- ('sendAndPersistReply'), so stripping it would break sending.
-- Scans for an opener and drops through the next "]".
--
-- The English opener requires the colon ("[sticker:") so ordinary
-- prose like "[stickers are fun]" survives; the legacy opener stays
-- loose because "[表情包" starting anything else is never real text.
stripStickerText :: T.Text -> T.Text
stripStickerText t0 = foldl' stripOpener t0 ["[sticker:", "[sticker：", "[表情包"]
  where
    stripOpener t1 opener = go t1
      where
        go t = case T.breakOn opener t of
          (before, rest)
            | T.null rest -> t -- no opener left
            | otherwise ->
                let afterOpener = T.drop (T.length opener) rest
                 in if isSendToken afterOpener
                      then before <> opener <> go afterOpener -- keep the token, scan on
                      else case T.breakOn "]" afterOpener of
                        (_, close)
                          | T.null close -> before -- unterminated: drop the tail too
                          | otherwise -> before <> go (T.drop 1 close)
    -- "…#<digit>…" after the opener is a real send handle, not a
    -- hallucinated caption (only reachable via the legacy opener —
    -- the colon openers can't precede a '#').
    isSendToken s = case T.uncons s of
      Just ('#', r) -> maybe False (isDigit . fst) (T.uncons r)
      _ -> False
