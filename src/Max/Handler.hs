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

import Control.Concurrent.STM (TQueue, atomically, newTVarIO, readTQueue, readTVarIO, writeTVar)
import Control.Monad (unless, void, when)
import Data.Foldable (for_)
import Data.Char (isDigit, isSpace)
import Control.Applicative ((<|>))
import Data.List (find, partition)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Effectful
import Effectful.Concurrent.Async (Concurrent, async)
import Effectful.Exception (SomeException, catch, finally)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
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
import Max.Tasks (TaskCancelled (..), TaskId (..), TaskInfo (..), absorbedTriggers, beginDispatch, endDispatch, inFlightTriggers, listTasks, pushToLatest, pushToTrigger)
import Max.Reply (stripHallucinatedTokens)
import Max.ReplySend (ReplyTarget (..), canStream, freshBudget, sendAndPersistReply)
import Max.Util (catchSync, trySync)
import OneBot.Action (Action (..), Response (..), extractOutMid, sendChatMsg)
import OneBot.Event (Event (..), GroupMessage (..), PokeEvent (..), Sender (..))
import OneBot.Segment (Segment (..), mentionsUser, renderPlainText)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..), isPrivateChat)

-- | May this turn be swallowed by one already running?
--
-- The supplement classifier exists to guess what an unmarked
-- message meant, so a turn that already said it outright must not be
-- sent back for a second opinion — @!btw@ means \"leave the running
-- turn alone\", and a classifier that disagreed would do exactly the
-- thing the user ruled out.
--
-- Carried separately from 'TriggerOrigin' because the two ask
-- different questions.  Origin says what woke the bot (and the
-- reaction sites test it for \"is there a real trigger message to
-- react to\"); absorbable says whether this turn is up for grabs.
-- Direct and proactive triggers both are — a proactive followup
-- (\"不对，改成X\" said without an @) steers a running turn exactly
-- like the @-ed version of the same words.  A poke is not: it lands
-- in a running turn's inbox before ever dispatching (see 'onPoke'),
-- and the sentinel trigger it dispatches with has no message for the
-- classifier to read.
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
  -- Any addressed trigger stamps the gate's followup hot window.  The
  -- pending intent buffer is NOT cleared here: that happens inside
  -- 'dispatchLLM' at the moment a turn commits to building context —
  -- only then do the buffered messages actually reach a model as
  -- ambient text.  Clearing on every command was a hole: a pending
  -- "max帮我看看" (no @) was silently swallowed by an unrelated
  -- @!status@, which feeds no model at all.
  let noteActivity = for_ mIntent $ \st -> liftIO (noteBotActivity st gm.groupId)
  case trig of
    -- Not addressed: hand the message to the intent classifier —
    -- maybe the bot wants to join in anyway.
    TriggerNone -> for_ mIntent $ \st -> liftIO (enqueueIntent st gm)
    TriggerPong -> noteActivity >> sendPong gm
    TriggerCommand body -> noteActivity >> dispatchCommand mIntent gm body
    TriggerCommandError err -> replyText gm ("命令解析失败:\n" <> err)
    TriggerLLM _ -> noteActivity >> dispatchLLM mIntent OriginDirect MayAbsorb [] gm

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
      -- Stamp the followup hot window; the pending buffer survives —
      -- an injected poke feeds no model, so 'dispatchLLM' clears it
      -- only when the fallback dispatch actually builds context.
      for_ mIntent $ \st -> liftIO (noteBotActivity st pk.pkGroupId)
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
        Nothing -> dispatchLLM mIntent OriginPoke NeverAbsorb [] (pokeTrigger pk mName)

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
  Maybe IntentState ->
  GroupMessage ->
  T.Text ->
  Eff es ()
dispatchCommand mIntent gm body = localDomain "cmd" $ do
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
          -- Dispatch the message itself with only the !btw verb
          -- stripped — the same form 'recordAs' persisted.  Keeping
          -- the original segments is the point: a @!btw@ typed as a
          -- reply keeps its quote (buildContext reads the reply
          -- target out of the segments), and attached images keep
          -- their markers.  An earlier version rebuilt the segment
          -- list from the parsed body and silently dropped both.
          dispatchLLM mIntent OriginDirect NeverAbsorb [] (gm {message = stripVerb gm.message})
        -- !feedback: aim the note at the turn whose trigger the user
        -- replied to, and at the newest running turn otherwise — a
        -- reply to something that isn't a live turn (mis-click, a turn
        -- that has since finished) falls through rather than erroring,
        -- because a note that refuses to land ends up in nobody's
        -- context at all.  Nothing running is not an error either: the
        -- note is a question somebody asked the bot, so answer it as
        -- one — a fresh dispatch, absorbable so that a turn starting
        -- in the race window can still take it.  The one dead end is a
        -- @!use@-redirected note (a DM steering a group task) with no
        -- task to steer: a turn in the DM isn't what was asked for,
        -- so that alone keeps the failure face.
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
              -- A reply target only means something in the chat it was
              -- typed in: under a !use redirect the quoted mid belongs
              -- to the DM, and aiming it at the target group's turns
              -- could only ever miss.
              redirected = targetGid /= gm.groupId
          aimed <- case replyTarget of
            Just tgt | not redirected -> liftIO (pushToTrigger env.beTasks targetGid Nothing absorb tgt line)
            _ -> pure Nothing
          landed <- case aimed of
            Just _ -> pure aimed
            Nothing -> liftIO (pushToLatest env.beTasks targetGid Nothing absorb line)
          case landed of
            Just (TaskId into) -> do
              logInfo "feedback: explicit note" $
                object ["task" .= into, "aimed" .= isJust replyTarget]
              -- 托腮, not OK: the note is queued for a turn that may
              -- or may not still drain it, so the honest claim is
              -- "being chewed on", the same face the turn's own
              -- trigger wears.  The absorbing turn takes it back off
              -- when it ends (see the 'absorbedTriggers' sweep in
              -- 'dispatchLLM').
              sendAction (SetMsgEmojiLike gm.messageId processingFaceId True)
            Nothing
              | redirected -> do
                  let GroupId targetRaw = targetGid
                  logInfo "feedback: nothing running in redirect target" $
                    object ["group_id" .= targetRaw]
                  sendAction (SetMsgEmojiLike gm.messageId failureFaceId True)
              | otherwise -> do
                  logInfo "feedback: nothing running, answering as a turn" $
                    object ["len" .= T.length noteBody]
                  dispatchLLM mIntent OriginDirect MayAbsorb [] (gm {message = stripVerb gm.message})

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

-- | Entry point for the intent worker: dispatch a batch of messages
-- nobody @-ed at the bot (chronological, newest last), with the
-- prompt honestly labelled as a proactive turn (and @[silence]@
-- explicitly on the table).  The newest message is the trigger — a
-- fresh turn sees the rest as ambient history anyway — and the
-- earlier ones ride along as companions so that an absorbed batch
-- reaches the running turn whole.  Absorbable like a direct trigger:
-- an unaddressed followup landing while a turn is still running
-- steers that turn, it doesn't talk over it.
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
  Maybe IntentState ->
  [GroupMessage] ->
  Eff es ()
dispatchProactive mIntent batch = case reverse batch of
  [] -> pure ()
  (trigger : older) ->
    dispatchLLM mIntent OriginProactive MayAbsorb (reverse older) trigger

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
  Maybe IntentState ->
  TriggerOrigin ->
  Absorbable ->
  -- | Earlier messages of the same proactive batch (chronological),
  -- steering context that must ride along in the note if this turn is
  -- absorbed.  Empty for every other origin: a direct trigger or poke
  -- is one message.
  [GroupMessage] ->
  GroupMessage ->
  Eff es ()
dispatchLLM mIntent origin absorbable companions gm = do
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
          `finally` do
            -- Take the 托腮 back off everything this turn absorbed —
            -- implicit supplements and explicit !feedback notes both
            -- wear it from the moment they land in the inbox.  Read
            -- before 'endDispatch' drops the entry, but send after the
            -- bookkeeping: a throwing send must not leak the shutdown
            -- slot.  A mid that never had the reaction un-reacts as a
            -- no-op.
            absorbed <- liftIO (absorbedTriggers env.beTasks tid)
            liftIO $ do
              leaveDispatch env.beShutdown
              endDispatch env.beTasks tid
            for_ absorbed $ \m ->
              sendAction (SetMsgEmojiLike (MessageId m) processingFaceId False)
  where
    work tid = do
      env :: BotEnv <- ask
      t <- loadSession env.beSessions env.beDefaultModel gm.groupId
      s <- liftIO (readSession t)
      injected <- tryInjectSupplement env s tid
      unless injected $ do
        -- Commit point: this turn is going to build context, and the
        -- group's pending intent buffer reaches the model as ambient
        -- text of it — clear the buffer so the same messages can't
        -- also produce a proactive reply.  Not earlier (an absorbed
        -- trigger builds nothing, and the buffer must survive it) and
        -- not later (buildContext is about to read history).
        for_ mIntent $ \st -> liftIO (clearPendingIntent st gm.groupId)
        withProcessingReaction (dispatch env s)

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
    -- has another turn running, a fresh trigger is often steering
    -- that turn（追加要求、修正方向、催进度）rather than starting
    -- something new.  Ask the intent profile which it is; a supplement
    -- goes into a running turn's inbox — that turn's eventual reply
    -- addresses it — instead of spawning a parallel dispatch.  Anyone
    -- may steer, not just whoever started the turn: the note carries
    -- the speaker's name, so the model can address them.
    --
    -- Aiming mirrors @!feedback@: a trigger that replies to a running
    -- turn's trigger (or to a message that turn already absorbed) is
    -- steering THAT turn, not whichever started last — 'pushToTrigger'
    -- first, newest turn as the fallback.
    --
    -- Gated on intent being configured; turns that declared themselves
    -- un-absorbable never reroute — @!btw@ said so outright, and a
    -- poke has no message for the classifier to read.  Direct and
    -- proactive triggers both may: the same "不对，改成X" steers the
    -- running turn whether or not it carried an @.  Any doubt
    -- (classifier says no, errors out, or the turn finished while we
    -- were classifying) falls back to a normal dispatch.
    tryInjectSupplement env s tid =
      case env.beIntent of
        Just icfg | absorbable == MayAbsorb -> do
          -- Our own entry has been in the registry since dispatch
          -- entry, so "is anybody working?" has to discount it.
          running <- liftIO (listTasks env.beTasks (Just gm.groupId))
          if all (\ti -> ti.tiId == tid) running
            then pure False
            else do
              let GroupId gidRaw = gm.groupId
                  MessageId midRaw = gm.messageId
                  UserId selfRaw = gm.selfId
              rows <- fetchRecentInGroup gidRaw 0 s.clearedAt (icfg.icContextLines + length companions)
              noteAt <- liftIO getCurrentTime
              -- Companions (the earlier messages of a proactive batch)
              -- count as new alongside the trigger, not as context:
              -- the classifier judges the batch it was fired for, and
              -- if the turn absorbs, the whole batch is the note — the
              -- running turn never re-reads history, so a line left
              -- behind here is a line it never sees.  Rendered from
              -- their DB rows for real timestamps; a row missing in a
              -- pathological flood just drops its line, same call the
              -- intent worker already makes.
              let render = renderHistoryLine env.beTimeZone selfRaw
                  companionMids =
                    Set.fromList [m | c <- companions, let MessageId m = c.messageId]
                  rest = filter (\h -> h.messageId /= midRaw) rows
                  (companionRows, ctxRows) =
                    partition (\h -> h.messageId `Set.member` companionMids) rest
                  ctxLines = map render ctxRows
                  newLine =
                    T.intercalate "\n" $
                      map render companionRows <> [renderCurrentLine env.beTimeZone noteAt gm]
              isSupp <- classifySupplement icfg gidRaw ctxLines newLine
              if not isSupp
                then pure False
                else do
                  -- Record the trigger as absorbed by whichever turn
                  -- takes it: ours is about to exit and unmark it, and
                  -- a question that looks unanswered gets answered
                  -- again by the next dispatch.
                  aimed <- case listToMaybe [m | SegReply (MessageId m) <- gm.message] of
                    Just tgt ->
                      liftIO (pushToTrigger env.beTasks gm.groupId (Just tid) (Just midRaw) tgt newLine)
                    Nothing -> pure Nothing
                  landed <- case aimed of
                    Just _ -> pure aimed
                    Nothing ->
                      liftIO (pushToLatest env.beTasks gm.groupId (Just tid) (Just midRaw) newLine)
                  for_ landed $ \(TaskId into) -> do
                    logInfo "feedback: implicit injection" $
                      object
                        [ "group_id" .= gidRaw,
                          "message_id" .= midRaw,
                          "aimed" .= isJust aimed,
                          "task" .= into
                        ]
                    -- Same 托腮 an explicit !feedback gets, cleared by
                    -- the absorbing turn's epilogue.  Direct triggers
                    -- only: an absorbed proactive candidate was never
                    -- addressed to the bot, and reacting would break
                    -- the "traceless until it speaks" rule.
                    when (origin == OriginDirect) $
                      sendAction (SetMsgEmojiLike gm.messageId processingFaceId True)
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
          target = sendTarget env gm mentionable rosterNames stickersEff
      -- The streaming sink.  It sends whole paragraphs the model has
      -- finished with, down the same path the final reply takes — the
      -- budget TVar is what keeps the two halves of one split reply
      -- bounded together (see "Max.ReplySend").
      streamBudget <- liftIO (newTVarIO freshBudget)
      let emit para = do
            b <- liftIO (readTVarIO streamBudget)
            -- Refusing is how the message ceiling survives being split
            -- across N sends; see 'canStream'.  The loop keeps whatever
            -- we decline and it goes out with the final reply.
            if not (canStream b)
              then pure False
              else do
                b' <- sendAndPersistReply target b (cleanReply para)
                liftIO (atomically (writeTVar streamBudget b'))
                pure True
      result <- agentTurn dc s.model ctx emit
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
        Just replyRaw -> handleReply env s mentionable rosterNames streamBudget ctx result replyRaw

    handleReply env s mentionable rosterNames streamBudget ctx result replyRaw = do
      -- Real stickers/images are the [sticker#<id>] / [image#<id>]
      -- tokens, resolved when the reply is sent.  The captionless
      -- "[表情包: …]" and bare "[image]"/"[动画表情]"/"[face]"/…
      -- forms are hallucinations — a weaker model imitating the
      -- display style of something it saw — so strip those as a
      -- backstop while leaving the id-carrying send tokens intact
      -- (see 'stripStickerText' / 'stripBareMarkers').
      -- Whatever streaming already put in the group is gone from here:
      -- what's left to send is the tail.  'Max.Reply.readyPrefix' only
      -- ever cuts at a blank line, so dropping the prefix cannot split
      -- a paragraph — the remainder plans into chunks exactly as it
      -- would have on its own.
      let remaining = T.drop (T.length result.sentPrefix) replyRaw
          stickersEff = maybe env.beStickerDefault id s.stickerOverride
          cleaned = stripHallucinatedTokens remaining
          stripped = T.strip (stripBareMarkers (stripStickerText cleaned))
      when (cleaned /= remaining) $
        logAttention "reply: hallucinated bracket tokens stripped" $
          object ["dropped_chars" .= (T.length remaining - T.length cleaned)]
      -- A non-empty prefix means this reply already ran to at least two
      -- paragraphs, and the opt-out is never more than one — so it can
      -- only be the tail of a real answer, never a silence marker that
      -- happens to sit at the end.
      case if T.null result.sentPrefix then parseSilence stripped else Nothing of
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
          -- The same budget the streaming sink spent from: one reply
          -- split across two senders still gets one message ceiling and
          -- one image-dedupe set (see "Max.ReplySend").
          budget <- liftIO (readTVarIO streamBudget)
          _ <-
            sendAndPersistReply
              (sendTarget env gm mentionable rosterNames stickersEff)
              budget
              stripped
          logInfo "llm replied" $
            object
              [ "to" .= (let UserId u = gm.userId in u),
                "len" .= T.length stripped,
                "streamed" .= T.length result.sentPrefix,
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

-- | The send-side view of a dispatch: what "Max.ReplySend" needs that
-- the handler already has.  Built here rather than carried around,
-- because every field is derived from something the caller holds
-- anyway.
sendTarget ::
  BotEnv ->
  GroupMessage ->
  Maybe (Set UserId) ->
  [(T.Text, UserId)] ->
  Bool ->
  ReplyTarget
sendTarget env gm mentionable rosterNames stickersOn =
  ReplyTarget
    { rtGroupId = gm.groupId,
      rtSelfId = gm.selfId,
      rtMentionable = mentionable,
      rtRosterNames = rosterNames,
      rtBlobRoot = env.beBlobRoot,
      rtStickers = stickersOn
    }

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

-- | Everything that has to happen to model text before it can be sent:
-- drop the hallucinated bracket tokens, drop the bare display markers,
-- trim.  Shared by the streaming sink and the final reply so a
-- paragraph is cleaned the same whichever half of the split it lands
-- in.
cleanReply :: T.Text -> T.Text
cleanReply = T.strip . stripBareMarkers . stripStickerText . stripHallucinatedTokens

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
