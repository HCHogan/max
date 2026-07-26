module Max.Handler
  ( handleEvents,
    dispatchProactive,
    recordAs,
    stripStickerText,
    stripBareMarkers,
    isSilentReply,
    parseSilence,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TQueue, atomically, newTVarIO, readTQueue, readTVarIO)
import Control.Monad (foldM_, unless, void, when)
import Data.Foldable (for_)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Char (isDigit, isSpace)
import Data.Int (Int64)
import Control.Applicative ((<|>))
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (getCurrentTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.Concurrent.Async (Concurrent, async)
import Effectful.Exception (SomeException, catch, finally)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
import System.FilePath ((</>))
import System.Random (randomRIO)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Command.Dispatcher qualified as CmdDispatch
import Max.Command.Dispatcher (DispatchResult (..))
import Max.Command.Parser (parseCommand)
import Max.Command.Permission (PermTier (..), requiredCapability, tierSatisfied)
import Max.Command.Types (Command (..))
import Max.DB.Permissions (lookupGrant)
import Max.DB.History (HistoryItem (..), fetchMessage, fetchRecentInGroup)
import Max.DB.Message (MessageKind (..), insertGroupMessage, insertOutbound, insertSilence)
import Max.Effects.Agent (Agent, AgentResult (..), DispatchContext (..), agentTurn)
import Max.Effects.LLM (LLM, isProfileHistoryTurns, isProfileMultimodal)
import Max.Effects.NapCat (NapCat, callAction, sendAction)
import Max.Env (BotEnv (..))
import Max.Faces (faceIdByName)
import Max.FetchQueue (FetchSignal)
import Max.Files (enqueueFiles)
import Max.MemoryExtract (extractMemories)
import Max.Forward (enqueueForwards)
import Max.Images (enqueueImages)
import Max.Intent (IntentConfig (..), IntentState, classifySupplement, clearPendingIntent, enqueueIntent, noteBotActivity)
import Max.Prompt (TriggerOrigin (..), buildContext, renderCurrentLine, renderHistoryLine)
import Max.Roster (GroupMember (..), fetchGroupMembers, fetchGroupMeta, memberName, renderGroupBrief)
import Max.Session (Session (..), loadSession, readSession, updateSession)
import Max.Shutdown (enterDispatch, leaveDispatch)
import Max.Tasks (TaskCancelled (..), TaskId (..), TaskInfo (..), beginDispatch, endDispatch, inFlightTriggers, listTasks, pushToLatest, pushToTrigger)
import Max.Render (renderTableImage)
import Max.Reply (Chunk (..), ReplyPiece (..), dedupeImagePieces, parseReplyTokens, planReply, stripHallucinatedTokens)
import Max.Sticker (resolveSticker)
import Max.Util (catchSync, trySync)
import OneBot.Action (Action (..), Response (..), extractOutMid, sendChatMsg)
import OneBot.Event (Event (..), GroupMessage (..), PokeEvent (..), Sender (..))
import OneBot.Segment (Segment (..), imageSeg, mentionsUser, renderPlainText, rescueNameMentions, segmentMentions)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)

-- | May this turn be swallowed by one already running?
--
-- The supplement classifier exists to guess what an unmarked
-- @-message meant, so a turn that already said it outright must not be
-- sent back for a second opinion — @!btw@ means \"leave the running
-- turn alone\", and a classifier that disagreed would do exactly the
-- thing the user ruled out.
--
-- Carried separately from 'TriggerOrigin' because the two ask
-- different questions.  Of the five places that test @origin ==
-- OriginDirect@, four mean \"there is a real trigger message to react
-- to\" and want a @!btw@ turn treated like any other; only the
-- classifier means \"this turn is up for grabs\".  A fourth origin
-- would have to be widened back in at four sites and would turn every
-- future @== OriginDirect@ into a trap.
--
-- This used to ride on 'Max.Persistence.isEphemeral' — @!btw@ ran in a
-- non-persisting scope, and the classifier skipped non-persisting
-- turns.  True by accident, and it broke the moment @!btw@ stopped
-- being ephemeral.
data Absorbable
  = MayAbsorb
  | NeverAbsorb
  deriving stock (Show, Eq)

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

-- | How a freshly received message is recorded: its kind, and a
-- rewritten @rendered_text@ when the stored form should differ from
-- what was literally typed.
--
-- Most commands are the UI used to operate the bot, and the model has
-- no business reading them back.  @!btw@ and @!feedback@ are the
-- exception — their bodies are things somebody said *to* the bot, and
-- the bot answers them.  They are conversation wearing a command
-- prefix, so they record as 'KindChat' with the verb stripped, landing
-- in the transcript exactly where the implicit supplement path already
-- puts the same words.  An empty body isn't conversation, it's a
-- mistyped command, and stays 'KindCommand'.
--
-- @segments@ is stored verbatim either way; only the rendered text is
-- rewritten — the same split 'Max.DB.Message.insertOutbound' already
-- makes for a table sent as an image.
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
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  TQueue Event ->
  -- | Wakes the media workers after each ingest; the jobs themselves
  -- go to @fetch_jobs@ (see "Max.FetchQueue").
  FetchSignal ->
  Maybe IntentState -> -- proactive-trigger buffers ('Nothing' = feature off)
  Eff es ()
handleEvents q fetchSig mIntent = loop
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
          enqueueImages fetchSig gm
          enqueueForwards fetchSig gm
          enqueueFiles fetchSig gm
          onGroupMessage mIntent gm
        EvPoke pk -> onPoke mIntent pk
        -- Auto-approve friend requests: being friends is what makes
        -- private query delivery (silent commands) reliable on QQ —
        -- NapCat has no API to *initiate* friendships, so we accept
        -- every incoming one instantly instead.
        EvFriendRequest flag (UserId uidRaw) -> do
          logInfo "friend request: auto-approving" $ object ["user_id" .= uidRaw]
          sendAction (SetFriendAddRequest flag True)
      loop

-- | Persistence runs before any dispatch decision, so it re-derives
-- "is this a command" from the same parser 'classify' uses rather than
-- waiting for the trigger — the DB lookup 'classify' needs for
-- reply-to-bot has nothing to do with it.  A malformed command counts:
-- it still looks like one to the reader, and it gets an error reply
-- rather than an answer.
persist :: (Log :> es, WithConnection :> es, IOE :> es) => GroupMessage -> Eff es ()
persist gm =
  trySync (uncurry insertGroupMessage (recordAs gm) gm) >>= \case
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
  -- A direct trigger clears the group's pending intent buffer (those
  -- messages reach the model as ambient context of this turn, and
  -- must not also produce a second, proactive reply) and stamps the
  -- gate's followup hot window.
  let clearIntent = for_ mIntent $ \st -> liftIO $ do
        clearPendingIntent st gm.groupId
        noteBotActivity st gm.groupId
  case trig of
    -- Not addressed: hand the message to the intent classifier —
    -- maybe the bot wants to join in anyway.
    TriggerNone -> for_ mIntent $ \st -> liftIO (enqueueIntent st gm)
    TriggerPong -> clearIntent >> sendPong gm
    TriggerCommand body -> clearIntent >> dispatchCommand gm body
    TriggerCommandError err -> replyText gm ("命令解析失败:\n" <> err)
    TriggerLLM _ -> clearIntent >> dispatchLLM OriginDirect MayAbsorb gm

-- | A 戳一戳 aimed at the bot: a contentless direct wake, the soft
-- version of an @.  If the group already has a running turn the poke
-- reads as a nudge and goes into its feedback inbox; otherwise it
-- starts a normal dispatch with 'OriginPoke' so the prompt says
-- honestly who poked (and that there is no message).  Pokes between
-- other members, and echoes of the bot's own outbound pokes, are
-- ignored.
onPoke ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
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
      -- proactive classification and stamps the followup hot window.
      for_ mIntent $ \st -> liftIO $ do
        clearPendingIntent st pk.pkGroupId
        noteBotActivity st pk.pkGroupId
      -- Best-effort display name for the poker (groups only; the
      -- private-chat peer needs no introduction).
      mName <-
        if isPrivateChat pk.pkGroupId
          then pure Nothing
          else do
            members <- fetchGroupMembers pk.pkGroupId
            pure (memberName <$> (find (\m -> m.mUserId == pk.pkUserId) =<< members))
      let pokerName = maybe (T.pack (show pokerRaw)) id mName
      -- A poke has no content for the classifier to judge, so it takes
      -- the same route an explicit !feedback does: into whatever turn
      -- the group has running, whoever started it.  Nothing running →
      -- a dispatch of its own.
      landed <-
        liftIO $
          pushToLatest env.beTasks pk.pkGroupId Nothing Nothing (pokerName <> " 戳了戳你")
      case landed of
        Just (TaskId into) ->
          logInfo "poke: injected into running task" $
            object ["group_id" .= gidRaw, "task" .= into]
        Nothing -> dispatchLLM OriginPoke MayAbsorb (pokeTrigger pk mName)

-- | Synthesize the trigger 'GroupMessage' for a poke dispatch.  There
-- is no real message: id 0 is the "no trigger message" sentinel —
-- nothing quotes or reacts to it, and 'Max.Tasks.beginDispatch' reads
-- it as no trigger rather than as an id every poke shares — and the
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
      targetGid <- resolveAdminTarget env gm cmd
      effTier <- effectiveTier env targetGid gm
      allowed <- checkCmdPermission targetGid gm.userId effTier cmd
      if not allowed
        then do
          let UserId uidRaw = gm.userId
          logInfo "command denied" $
            object ["cmd" .= T.pack (show cmd), "user_id" .= uidRaw]
          -- Same NO face as [silence:NO]: visibly refused, zero noise.
          sendAction (SetMsgEmojiLike gm.messageId deniedFaceId True)
        else dispatchAllowed env targetGid effTier cmd
  where
    dispatchAllowed env targetGid effTier cmd = do
      t <- loadSession env.beSessions env.beDefaultModel targetGid
      logInfo "command" $ object ["cmd" .= T.pack (show cmd)]
      let replyTarget = listToMaybe [m | SegReply (MessageId m) <- gm.message]
      result <- CmdDispatch.execute t targetGid gm.userId effTier replyTarget cmd
      case result of
        -- In a group, textual command output (queries, error texts)
        -- goes to the sender's DMs — the group only sees an OK
        -- reaction.  Private chats reply inline as before.  When the
        -- DM can't be delivered (not friends; QQ throttles temp
        -- sessions), fall back to the group with a befriend hint.
        ReplyText reply
          | isPrivateChat gm.groupId -> replyText gm reply
          | otherwise -> deliverPrivate reply
        -- Deliberately group-audience output (e.g. !version).
        ReplyPublicText reply -> replyText gm reply
        -- Pure acknowledgement: an OK reaction on the command message
        -- beats another line of chat noise.
        ReplyAck ->
          sendAction (SetMsgEmojiLike gm.messageId ackFaceId True)
        SideQuestion askBody -> do
          logInfo "btw: side question" $
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
          dispatchLLM OriginDirect NeverAbsorb virtualGm
        -- !feedback: aim the note at the turn whose trigger the user
        -- replied to, and at the newest running turn otherwise — a
        -- reply to something that isn't a live turn (mis-click, a turn
        -- that has since finished) falls through rather than erroring,
        -- because a note that refuses to land ends up in nobody's
        -- context at all.  Nothing running anywhere is the one case
        -- with no home for it: say so with the failure face, quietly.
        FeedbackNote noteBody -> do
          noteAt <- liftIO getCurrentTime
          let line = renderCurrentLine env.beTimeZone noteAt (gm {message = [SegText noteBody]})
              -- The !feedback message records as chat (verb stripped),
              -- so it is a visible question in the transcript with the
              -- answer threaded at someone else's message.  Mark it
              -- absorbed for the lifetime of the turn that took it, or
              -- a concurrent dispatch answers it a second time — the
              -- implicit path has needed this all along.
              MessageId noteMid = gm.messageId
              absorb = Just noteMid
          aimed <- case replyTarget of
            Just tgt -> liftIO (pushToTrigger env.beTasks targetGid Nothing absorb tgt line)
            Nothing -> pure Nothing
          landed <- case aimed of
            Just _ -> pure aimed
            Nothing -> liftIO (pushToLatest env.beTasks targetGid Nothing absorb line)
          case landed of
            Just (TaskId into) -> do
              logInfo "feedback: explicit note" $
                object ["task" .= into, "aimed" .= isJust replyTarget]
              sendAction (SetMsgEmojiLike gm.messageId ackFaceId True)
            Nothing -> do
              let GroupId targetRaw = targetGid
              logInfo "feedback: nothing running" $ object ["group_id" .= targetRaw]
              sendAction (SetMsgEmojiLike gm.messageId failureFaceId True)

    -- Recorded against the DM's pseudo-group rather than the group the
    -- command came from: that is the conversation it actually appeared
    -- in, and the record follows the chat.
    deliverPrivate reply = do
      let GroupId gidRaw = gm.groupId
          UserId uidRaw = gm.userId
          header = "（群 " <> T.pack (show gidRaw) <> " 的命令结果）\n"
          segs = [SegText (header <> reply)]
      res <- callAction (SendPrivateMsg gm.userId segs) 15000
      case res of
        Right (Response _ rc payload _)
          | rc == 0 -> do
              for_ (extractOutMid payload) $ \outMid ->
                insertOutbound
                  KindCommand
                  (GroupId (negate uidRaw))
                  gm.selfId
                  "max"
                  (MessageId outMid)
                  Nothing
                  segs
              sendAction (SetMsgEmojiLike gm.messageId ackFaceId True)
        _ -> do
          logInfo "cmd: private delivery failed, group fallback" $
            object ["user_id" .= uidRaw, "group_id" .= gidRaw]
          replyText gm (reply <> "\n\n（加我好友后，这类结果会私聊发你，不刷群）")

--------------------------------------------------------------------------------
-- LLM dispatch.

-- | @ping@ is an ordinary exchange that happens not to cost an LLM
-- call, so it records as 'KindChat' — the trigger is in the transcript
-- and an answer that wasn't would read as a question nobody answered.
sendPong ::
  (NapCat :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  GroupMessage ->
  Eff es ()
sendPong gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
  sendAndRecord KindChat gm.groupId gm.selfId (replySegs gm " pong")
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
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  GroupMessage ->
  Eff es ()
dispatchProactive = dispatchLLM OriginProactive MayAbsorb

-- | Spawn an async to build the prompt, call the LLM, post the reply,
-- and append the (user, assistant) turn to the session history.
-- The 'TriggerOrigin' says what woke the bot — see
-- 'Max.Prompt.PromptInputs.origin'.
--
-- This is the process's only asynchronous dispatch path (commands run
-- inline on the event loop, and memory extraction runs inside this
-- async), so it is also where graceful shutdown gates: once draining,
-- new triggers are logged and dropped rather than started.  See
-- "Max.Shutdown".
dispatchLLM ::
  ( Log :> es,
    WithConnection :> es,
    NapCat :> es,
    LLM :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    IOE :> es
  ) =>
  TriggerOrigin ->
  Absorbable ->
  GroupMessage ->
  Eff es ()
dispatchLLM origin absorbable gm = do
  env :: BotEnv <- ask
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
      MessageId midRaw = gm.messageId
      ident =
        object
          [ "group_id" .= gidRaw,
            "user_id" .= fromRaw,
            "message_id" .= midRaw,
            "origin" .= T.pack (show origin)
          ]
  -- Claim the shutdown slot out here rather than inside the async:
  -- 'Max.Effects.Agent.agentTurn' doesn't reach its 'registerTask'
  -- until after 'Max.Prompt.buildContext', which on its own can spend
  -- 30s waiting for the trigger's images, so a drain watching only the
  -- task registry would walk straight past a dispatch sitting in that
  -- gap.  Claiming before the spawn also closes the race the other
  -- way: 'enterDispatch' and the drain flag share one transaction.
  started <- liftIO (enterDispatch env.beShutdown)
  -- Same reason the shutdown slot is claimed here: the agent loop is
  -- tens of seconds away, and until it attaches, a concurrent trigger
  -- has to be able to see this question is already taken — as do !ps
  -- and !kill.  The registry entry opens now and the loop adopts it.
  mTask <-
    if started
      then Just <$> liftIO (beginDispatch env.beTasks gm.groupId gm.userId (Just gm.messageId))
      else pure Nothing
  case mTask of
    Nothing -> do
      logInfo "llm dispatch declined: draining" ident
      -- The drain can run for a couple of minutes behind a long turn,
      -- and every @ landing in that window would otherwise get total
      -- silence — the one failure mode worth being loud about.  A face
      -- says "seen, not doing it" without a line of chat noise, same
      -- as the crash and denied-command paths.  Direct triggers only:
      -- proactive turns stay traceless and a poke has no message to
      -- react to.
      when (origin == OriginDirect) $
        sendAction (SetMsgEmojiLike gm.messageId failureFaceId True)
    Just tid ->
      void . async $
        ( localDomain "llm" $ do
            logInfo "llm dispatch" ident
            -- 'TaskCancelled' is async-tagged, so it flies past 'catchSync'
            -- (and every trySyncIO on the way up) — the outer 'catch' is the
            -- one place a user-initiated @!kill@ comes to rest.
            ( work tid `catchSync` \e -> do
                logAttention "llm dispatch crashed" $
                  object ["error" .= T.pack (show (e :: SomeException))]
                -- The processing reaction is already gone (its 'finally' ran
                -- while the exception unwound), which without this looked
                -- exactly like a silent success: 托腮 vanished, no reply, no
                -- face.  Swap in the failure face so a crash is visibly a
                -- crash — direct triggers only; proactive turns stay
                -- traceless, and a poke has no message to react to.
                when (origin == OriginDirect) $
                  sendAction (SetMsgEmojiLike gm.messageId failureFaceId True)
              )
              `catch` \TaskCancelled ->
                -- User-initiated !kill — quieter log, not an error.
                logInfo "llm dispatch cancelled" $
                  object ["group_id" .= gidRaw]
        )
          `finally` liftIO
            ( do
                leaveDispatch env.beShutdown
                endDispatch env.beTasks tid
            )
  where
    work tid = do
      env :: BotEnv <- ask
      t <- loadSession env.beSessions env.beDefaultModel gm.groupId
      s <- liftIO (readSession t)
      injected <- tryInjectSupplement env s tid
      unless injected (withProcessingReaction (dispatch env s))

    -- React [托腮] on the trigger while the dispatch runs — a quiet
    -- "seen, working on it" — and clear it once the reply (or
    -- silence / crash / !kill) lands.  Fire-and-forget both ways: a
    -- failed reaction must never affect the dispatch.  Proactive
    -- turns show it too (the bot IS working; a busy pause with no
    -- tell reads as ignoring the group) — but their [silence] leaves
    -- no other trace: the 托腮 just vanishes, no reason face.  Pokes
    -- have no message to react to.
    withProcessingReaction act
      | origin == OriginPoke = act
      | otherwise =
          (sendAction (SetMsgEmojiLike gm.messageId processingFaceId True) >> act)
            `finally` sendAction (SetMsgEmojiLike gm.messageId processingFaceId False)

    -- The implicit half of the feedback split: when the group already
    -- has another turn running, a fresh @-trigger is often steering
    -- that turn（追加要求、修正方向、催进度）rather than starting
    -- something new.  Ask the intent profile which it is; a supplement
    -- goes into the running turn's inbox — that turn's eventual reply
    -- addresses it — instead of spawning a parallel dispatch.  Anyone
    -- may steer, not just whoever started the turn: the note carries
    -- the speaker's name, so the model can address them.
    --
    -- Gated on intent being configured; proactive turns and turns that
    -- already declared themselves un-absorbable (@!btw@) never reroute.
    -- Any doubt (classifier says no, errors out, or the turn finished
    -- while we were classifying) falls back to a normal dispatch.
    tryInjectSupplement env s tid =
      case env.beIntent of
        Just icfg | origin == OriginDirect && absorbable == MayAbsorb -> do
          -- Our own entry has been in the registry since dispatch
          -- entry, so "is anybody working?" has to discount it.
          running <- liftIO (listTasks env.beTasks (Just gm.groupId))
          if all (\ti -> ti.tiId == tid) running
            then pure False
            else do
              let GroupId gidRaw = gm.groupId
                  MessageId midRaw = gm.messageId
                  UserId selfRaw = gm.selfId
              rows <- fetchRecentInGroup gidRaw 0 s.clearedAt icfg.icContextLines
              noteAt <- liftIO getCurrentTime
              let ctxLines =
                    map (renderHistoryLine env.beTimeZone selfRaw) $
                      filter (\h -> h.messageId /= midRaw) rows
                  newLine = renderCurrentLine env.beTimeZone noteAt gm
              isSupp <- classifySupplement icfg ctxLines newLine
              if not isSupp
                then pure False
                else do
                  -- Record the trigger as absorbed by whichever turn
                  -- takes it: ours is about to exit and unmark it, and
                  -- a question that looks unanswered gets answered
                  -- again by the next dispatch.
                  landed <-
                    liftIO $
                      pushToLatest env.beTasks gm.groupId (Just tid) (Just midRaw) newLine
                  for_ landed $ \(TaskId into) ->
                    logInfo "feedback: implicit injection" $
                      object
                        [ "group_id" .= gidRaw,
                          "message_id" .= midRaw,
                          "task" .= into
                        ]
                  pure (isJust landed)
        _ -> pure False

    dispatch env s = do
      multimodal <- isProfileMultimodal s.model
      historyTurns <- isProfileHistoryTurns s.model
      (mentionable, rosterNames, brief) <- fetchGroupContext gm.groupId
      -- Questions another turn is already working on.  Ours is in there
      -- too (claimed just above) — drop it, it isn't history yet.
      let MessageId ownMid = gm.messageId
      inFlight <- Set.delete ownMid <$> liftIO (inFlightTriggers env.beTasks gm.groupId)
      (ctx, movedAnchor) <-
        buildContext
          env.bePersona
          env.beHistoryWindow
          env.beHistoryMax
          multimodal
          historyTurns
          origin
          env.beBlobRoot
          env.beTimeZone
          brief
          inFlight
          s
          gm
      -- Commit the transcript anchor before the turn runs, not after:
      -- a crash mid-dispatch would otherwise rebuild the same
      -- over-long window next time and re-decide the same move.  It is
      -- bookkeeping either way — the worst a lost write costs is one
      -- more cache miss.
      for_ movedAnchor $ \anchor -> do
        t <- loadSession env.beSessions env.beDefaultModel gm.groupId
        updateSession t (\sess -> (sess {contextAnchor = Just anchor}, ()))
        logInfo "context anchor moved" $
          object ["group_id" .= (let GroupId g = gm.groupId in g)]
      toolImgs <- liftIO (newTVarIO (0, []))
      let debugEff = maybe env.beDebugDefault id s.debugOverride
          stickersEff = maybe env.beStickerDefault id s.stickerOverride
          dc = DispatchContext gm.groupId gm.messageId gm.userId gm.selfId debugEff multimodal stickersEff mentionable toolImgs
      result <- agentTurn dc s.model ctx
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
        Just replyRaw -> handleReply env s mentionable rosterNames ctx result replyRaw

    handleReply env s mentionable rosterNames ctx result replyRaw = do
      -- Real stickers/images are the [sticker#<id>] / [image#<id>]
      -- tokens, resolved when the reply is sent.  The captionless
      -- "[表情包: …]" and bare "[image]"/"[动画表情]"/"[face]"/…
      -- forms are hallucinations — a weaker model imitating the
      -- display style of something it saw — so strip those as a
      -- backstop while leaving the id-carrying send tokens intact
      -- (see 'stripStickerText' / 'stripBareMarkers').
      let stickersEff = maybe env.beStickerDefault id s.stickerOverride
          cleaned = stripHallucinatedTokens replyRaw
          stripped = T.strip (stripBareMarkers (stripStickerText cleaned))
      when (cleaned /= replyRaw) $
        logAttention "reply: hallucinated bracket tokens stripped" $
          object ["dropped_chars" .= (T.length replyRaw - T.length cleaned)]
      case parseSilence stripped of
        Just mFace -> do
          -- The model opted out of replying (see 'parseSilence') —
          -- the escape hatch for turns that need no response, most
          -- importantly another bot @-ing us: answering would
          -- re-trigger it and ping-pong forever.  Nothing is sent;
          -- btw notes are NOT drained (they wait for a turn that
          -- actually delivers them); no memory extraction (a turn
          -- judged not worth answering is noise).  The silence itself
          -- IS persisted, as a synthetic bot row — without it the
          -- declined question reads as still pending in the next
          -- dispatch's mention history and gets answered a turn late.
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
          insertSilence gm (if T.null stripped then "[silence]" else stripped)
          when (origin == OriginDirect) $
            sendAction
              (SetMsgEmojiLike gm.messageId (maybe defaultSilenceFace id mFace) True)
        Nothing -> do
          -- callAction so we get the message_id back, then persist this
          -- outbound message into the messages table.  That's where
          -- subsequent dispatches will read this turn's assistant reply
          -- back from when reconstructing mention history.
          sendAndPersistReply gm mentionable rosterNames env.beBlobRoot stickersEff stripped
          logInfo "llm replied" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "len" .= T.length stripped,
                "turns" .= result.turnsUsed,
                "appended" .= length result.appended,
                "aborted" .= result.aborted
              ]
          -- Post-reply memory extraction: the user already has their
          -- answer, so this costs them nothing.  A crashed extraction
          -- only logs.
          for_ env.beMemoryExtract $ \prof ->
            extractMemories prof env.beEmbed gm (ctx <> result.appended)
              `catchSync` \e ->
                logAttention "memx: crashed" $
                  object ["error" .= T.pack (show e)]

--------------------------------------------------------------------------------
-- Reply helper.

-- | Send a message and write it down, so the messages table mirrors
-- what the conversation actually saw.
--
-- Recording requires the round-trip: @message_id@ is assigned by QQ
-- and only comes back in the send response, and it is the table's
-- primary key — the id every @[↩#id]@ quote and reply link resolves
-- against.  Fire-and-forget cannot record anything.
--
-- Every failure only logs.  A message that went out but couldn't be
-- written down leaves the record incomplete, which is bad; failing the
-- dispatch over it is worse.
sendAndRecord ::
  (NapCat :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  MessageKind ->
  GroupId ->
  UserId -> -- bot self id
  [Segment] ->
  Eff es ()
sendAndRecord kind gid selfId segs =
  callAction (sendChatMsg gid segs) 15000 >>= \case
    Left err -> logAttention "send failed" $ object ["error" .= err, "kind" .= T.pack (show kind)]
    Right (Response _ rc payload _)
      | rc /= 0 ->
          logAttention "send retcode bad" $ object ["retcode" .= rc, "kind" .= T.pack (show kind)]
      | otherwise -> case extractOutMid payload of
          Nothing ->
            logAttention "no message_id in send response" $
              object ["payload" .= payload, "kind" .= T.pack (show kind)]
          Just outMid ->
            insertOutbound kind gid selfId "max" (MessageId outMid) Nothing segs

-- | Command output: plain text, no quote and no @ — in the moment
-- right after a command both read as noise.  Recorded as
-- 'KindCommand', so the group's record is complete but the model
-- doesn't read back the UI used to operate it.
replyText ::
  (NapCat :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  GroupMessage ->
  T.Text ->
  Eff es ()
replyText gm body =
  sendAndRecord KindCommand gm.groupId gm.selfId [SegText body]

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
    Log :> es,
    IOE :> es
  ) =>
  GroupMessage ->
  Maybe (Set UserId) ->
  [(T.Text, UserId)] -> -- roster display names, for "@名字" rescue
  FilePath -> -- blob store root (for inline sticker resolution)
  Bool -> -- whether sticker sending is enabled for this group
  T.Text ->
  Eff es ()
sendAndPersistReply gm mentionable rosterNames blobRoot stickersOn body = do
  foldM_
    ( \sentImgs (i, chunk) -> do
        (sentImgs', mPlan) <- planChunk sentImgs chunk
        case mPlan of
          Nothing -> pure ()
          Just (segs, rendered) -> do
            -- Typing-pace delay between chunks: instant multi-message
            -- bursts read as a bot.  The first chunk needs none — the
            -- LLM round-trip already was its "typing time".
            when (i > 0) $
              liftIO (threadDelay =<< chunkDelayMicros (T.length rendered))
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
                      insertOutbound
                        KindChat
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
             in Just (prefix <> trimEdgeSegs content, T.strip rendered)

    -- Extracted tokens leave whitespace seams at the chunk's edges
    -- (e.g. "[↩#id] 说得对" starts the sent text with a space once the
    -- quote token is gone).  Trim the outermost text segments; an
    -- edge segment that was pure whitespace disappears entirely.
    trimEdgeSegs segs =
      let start = case segs of
            (SegText x : rest) ->
              let x' = T.stripStart x
               in if T.null x' then rest else SegText x' : rest
            _ -> segs
       in case reverse start of
            (SegText x : rest) ->
              let x' = T.stripEnd x
               in reverse (if T.null x' then rest else SegText x' : rest)
            _ -> start

    -- Resolve parsed pieces into (segments, normalised rendered text).
    resolvePieces pieces = do
      parts <- traverse resolve pieces
      pure (concatMap fst parts, T.concat (map snd parts))
      where
        resolve (PieceText t0) =
          -- "@显示名" → canonical [@#id] first (small models skip the
          -- roster lookup), then the usual mention conversion.
          let t = rescueNameMentions rosterNames t0
           in pure (mentionSegs t, t)
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

-- | How long to pause before a follow-up chunk, roughly scaled to how
-- long a human would take to type it: ~35ms per character with ±30%
-- jitter, clamped to [200ms, 2s].
chunkDelayMicros :: Int -> IO Int
chunkDelayMicros nChars = do
  f <- randomRIO (0.7, 1.3 :: Double)
  pure (max 200_000 (min 2_000_000 (round (fromIntegral nChars * 35_000 * f))))

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
  Eff es (Maybe (Set UserId), [(T.Text, UserId)], [T.Text])
fetchGroupContext gid
  | isPrivateChat gid = pure (Nothing, [], [])
  | otherwise = do
      members <- fetchGroupMembers gid
      meta <- fetchGroupMeta gid
      -- Display-name → id pairs (card > nickname, blanks skipped) for
      -- rescuing "@显示名" spans in replies — see 'rescueNameMentions'.
      let names =
            [ (nm, m.mUserId)
            | m <- maybe [] id members,
              Just nm <- [nonBlankName m.mCard <|> nonBlankName m.mNickname]
            ]
      pure
        ( Set.fromList . map (.mUserId) <$> members,
          names,
          renderGroupBrief meta members
        )
  where
    nonBlankName (Just t) | not (T.null (T.strip t)) = Just (T.strip t)
    nonBlankName _ = Nothing

stripMentions :: UserId -> T.Text -> T.Text
stripMentions (UserId u) t =
  foldr
    (\m acc -> T.replace m "" acc)
    t
    ["[@#" <> uid <> "] ", "[@#" <> uid <> "]", "@" <> uid]
  where
    uid = T.pack (show u)

-- | The group a private-chat command actually operates on: the
-- @!use@ target when one is set (and the sender is entitled to it),
-- else the chat's own (pseudo) group.  The !use family itself never
-- redirects — it manages the selection.  Entitlement: owners aim
-- anywhere; anyone else must be a member of the target group, which
-- also closes the "!use someone else's group and read its !status"
-- hole.
resolveAdminTarget ::
  (NapCat :> es, Log :> es, IOE :> es) =>
  BotEnv ->
  GroupMessage ->
  Command ->
  Eff es GroupId
resolveAdminTarget env gm cmd
  | not (isPrivateChat gm.groupId) = pure gm.groupId
  | useFamily cmd = pure gm.groupId
  | otherwise = do
      let UserId uidRaw = gm.userId
      targets <- liftIO (readTVarIO env.beAdminTarget)
      case Map.lookup uidRaw targets of
        Nothing -> pure gm.groupId
        Just g
          | uidRaw `elem` env.beOwners -> pure (GroupId g)
          | otherwise -> do
              members <- fetchGroupMembers (GroupId g)
              if any (\m -> m.mUserId == gm.userId) (maybe [] id members)
                then pure (GroupId g)
                else do
                  logInfo "cmd: admin target dropped (not a member)" $
                    object ["user_id" .= uidRaw, "target" .= g]
                  pure gm.groupId
  where
    useFamily = \case
      UseShow -> True
      UseSet _ -> True
      UseClear -> True
      _ -> False

-- | The sender's effective tier IN THE TARGET GROUP: config owner
-- list first, then the NapCat role there.  Resolved once per command
-- and threaded into both the permission check and
-- 'CmdDispatch.execute' (which needs it for !grant's constraints).
effectiveTier :: (NapCat :> es, Log :> es) => BotEnv -> GroupId -> GroupMessage -> Eff es PermTier
effectiveTier env targetGid gm
  | let UserId uid = gm.userId, uid `elem` env.beOwners = pure TierOwner
  | otherwise = actorTier targetGid gm.userId

-- | Resolve whether the sender may run this command against the
-- target group.  Order (first hit wins): owner tier > explicit
-- grant/deny row (group scope beats global) > role tier default.
-- Commands without a capability are open to all.
checkCmdPermission ::
  (WithConnection :> es, IOE :> es) =>
  GroupId ->
  UserId ->
  PermTier ->
  Command ->
  Eff es Bool
checkCmdPermission (GroupId gid) (UserId uid) effTier cmd = case requiredCapability cmd of
  Nothing -> pure True
  Just (cap, tier)
    | effTier == TierOwner -> pure True
    | otherwise ->
        lookupGrant uid cap gid >>= \case
          Just explicit -> pure explicit
          Nothing -> pure (tierSatisfied tier effTier)

-- | The sender's role tier in a group.  A private pseudo-group means
-- the sender administers their own session by definition; owner tier
-- is config-only and resolved by the caller.
actorTier :: (NapCat :> es, Log :> es) => GroupId -> UserId -> Eff es PermTier
actorTier gid uid
  | isPrivateChat gid = pure TierGroupAdmin
  | otherwise = do
      members <- fetchGroupMembers gid
      let role = [m.mRole | m <- maybe [] id members, m.mUserId == uid]
      pure $ case role of
        (r : _) | r `elem` ["owner", "admin"] -> TierGroupAdmin
        _ -> TierMember

-- | Reaction for a permission-denied command: the NO face — same one
-- @[silence:NO]@ uses, visibly refused with zero chat noise.
deniedFaceId :: Int
deniedFaceId = 123

-- | The "processing" reaction face: 托腮 (chin-on-hand, thinking).
-- Face ids come from NapCat's face_config.json (QSid).
processingFaceId :: Int
processingFaceId = 212

-- | The command-acknowledged face: OK (the hand gesture) — replaces
-- the old "✓ …" text replies for pure acks.
ackFaceId :: Int
ackFaceId = 124

-- | The "request failed" reaction face: 裂开 — swapped in for
-- 'processingFaceId' when a dispatch produced no reply.  Distinct
-- from the /NO (123) that @[silence:NO]@ puts on refused (political)
-- topics: broken vs refused should read differently.
failureFaceId :: Int
failureFaceId = 357

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
  | Just inner <- withReason = Just (faceIdByName (T.strip inner))
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
