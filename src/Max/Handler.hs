module Max.Handler
  ( ingressWorker,
    dispatchProactive,
    onPoke,
  )
where

import Control.Monad (forever, unless)
import Data.Foldable (for_)
import Data.List (find, unsnoc)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Concurrent.Async (Concurrent)
import Effectful.Log
  ( Log,
    MonadLog (localDomain),
    logAttention,
    logInfo,
    object,
    (.=),
  )
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Command.Parser (parseCommand)
import Max.Command.Types (Command (..))
import Max.ConversationScope (conversationScopeFor)
import Max.DB.History (HistoryItem (fromBot), fetchMessageInScope, isTurnTriggerInScope)
import Max.Dispatch
  ( DispatchMessage (..),
    dispatchMentionsSelf,
    dispatchTextWithoutSelf,
    stripDispatchVerb,
  )
import Max.Effects.Agent (Agent)
import Max.Effects.Blob (Blob)
import Max.Effects.Outbound
  ( Outbound,
    OutboundDeliveryScope (DeliverConversation),
  )
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Env (BotEnv (..))
import Max.FetchQueue (FetchPriority (LiveFetch), FetchSignal)
import Max.Files (enqueueFiles)
import Max.Forward (enqueueForwards)
import Max.Handler.Command (dispatchCommand, routeTaskInput)
import Max.Handler.Output (replyText, sendAndRecord)
import Max.IR
  ( Body (Body),
    MentionTarget (MentionIdentity),
    Node (NMention, NText),
  )
import Max.IR.Digest (digest)
import Max.Images (enqueueImages)
import Max.Intent (IntentState, enqueueIntent, noteBotActivity)
import Max.MessageKind (MessageKind (KindChat))
import Max.ModelCatalog (ModelCatalog)
import Max.Platform.Ingress (nextIngress)
import Max.Platform.QQ (ensureQQEndpointFor)
import Max.Platform.Store.Endpoint
  ( RegisteredEndpoint (endpointId),
  )
import Max.Platform.Store.Identity
  ( ensureEndpointPrincipals,
    resolveMentionIdentities,
  )
import Max.Platform.Store.Ingest (loadDispatchMessage)
import Max.Platform.Types
  ( CanonicalMessageId (CanonicalMessageId),
    NativeUserId (NativeUserId),
    Platform (PlatformQQ),
    PrincipalId,
  )
import Max.Prompt
  ( TriggerOrigin (OriginDirect, OriginPoke, OriginProactive),
  )
import Max.Roster
  ( GroupMember (mUserId),
    fetchGroupMembers,
    memberName,
  )
import Max.Turn.Dispatch (dispatchLLM, dispatchLLMWith)
import Max.Turn.Start
  ( InputAdmission (StartSeparateTurn),
    TurnStart (NewTurn),
  )
import Max.Util (catchSync, tshow)
import OneBot.Event
  ( PokeEvent (..),
  )
import OneBot.Types
  ( GroupId (GroupId),
    UserId (UserId),
    isPrivateChat,
  )

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

-- | A dispatch failure is local to that message. It may already have run a
-- command, so leave the history for inspection and never replay it automatically.
ingressWorker ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    Outbound :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  FetchSignal ->
  Maybe IntentState ->
  Eff es ()
ingressWorker fetchSig mIntent = localDomain "dispatch" $ forever $ do
  env :: BotEnv <- ask
  canonical <- liftIO (nextIngress env.beIngress)
  (loadDispatchMessage canonical >>= mapM_ dispatch)
    `catchSync` \err ->
      logAttention
        "message dispatch failed; not replayed"
        (object ["canonical_message_id" .= canonical, "error" .= show err])
  where
    dispatch message = do
      enqueueImages LiveFetch fetchSig message
      enqueueForwards LiveFetch fetchSig message
      enqueueFiles LiveFetch fetchSig message
      onDispatchMessage mIntent message

onDispatchMessage ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    Outbound :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  Maybe IntentState ->
  DispatchMessage ->
  Eff es ()
onDispatchMessage mIntent gm = do
  routed <- routeTaskInput gm
  unless routed (onConversationMessage mIntent gm)

onConversationMessage ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    Outbound :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  Maybe IntentState -> DispatchMessage -> Eff es ()
onConversationMessage mIntent gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
  logInfo "group message" $
    object
      [ "group_id" .= gidRaw,
        "user_id" .= fromRaw,
        "content" .= digest gm.body
      ]
  -- Only query quoted history when the message was not otherwise addressed.
  trig <- case classifyDispatch False gm of
    TriggerNone
      | Just (CanonicalMessageId rid) <- gm.replyTo -> do
          taskReply <- isTurnTriggerInScope (conversationScopeFor gm.groupId) rid
          mQuoted <- fetchMessageInScope (conversationScopeFor gm.groupId) rid
          pure $
            if taskReply
              then classifyDispatch True gm
              else case mQuoted of
                Just quoted | quoted.fromBot -> classifyDispatch True gm
                _ -> TriggerNone
    t -> pure t
  -- Refresh the followup window, but retain buffered intent until LLM context
  -- consumes it. A command such as !status must not discard pending conversation.
  let noteActivity = for_ mIntent $ \st -> liftIO (noteBotActivity st gm.groupId)
  case trig of
    -- Not addressed: hand the message to the intent classifier —
    -- maybe the bot wants to join in anyway.
    TriggerNone -> for_ mIntent $ \st -> liftIO (enqueueIntent st gm)
    TriggerPong -> noteActivity >> sendPong gm
    TriggerCommand body
      | Right (Just (Btw question)) <- parseCommand body,
        not (T.null (T.strip question)) -> do
          noteActivity
          dispatchLLMWith (NewTurn StartSeparateTurn) mIntent OriginDirect (stripDispatchVerb gm)
      | otherwise -> noteActivity >> dispatchCommand mIntent gm body
    TriggerCommandError err -> replyText gm ("命令解析失败:\n" <> err)
    -- The queue retains eligibility and the original trigger until execution.
    TriggerLLM _ -> do
      noteActivity
      dispatchLLM mIntent OriginDirect gm

classifyDispatch :: Bool -> DispatchMessage -> Trigger
classifyDispatch repliesToBot gm =
  let stripped = T.strip (dispatchTextWithoutSelf gm)
      addressed =
        dispatchMentionsSelf gm
          || repliesToBot
          || isPrivateChat gm.groupId
   in case parseCommand stripped of
        Right (Just _) -> TriggerCommand stripped
        Left err -> TriggerCommandError err
        Right Nothing
          | not addressed -> TriggerNone
          | otherwise -> case stripped of
              "ping" -> TriggerPong
              _ -> TriggerLLM stripped

-- | Dispatch a poke aimed at the bot as 'OriginPoke', without inventing a message.
-- Ignore pokes between other members and echoes of the bot's own pokes.
onPoke ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    Outbound :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  Maybe IntentState ->
  PokeEvent ->
  Eff es ()
onPoke mIntent pk
  | pk.pkTargetId /= pk.pkSelfId || pk.pkUserId == pk.pkSelfId = pure ()
  | otherwise = do
      let GroupId gidRaw = pk.pkGroupId
          UserId pokerRaw = pk.pkUserId
      logInfo "poked" $ object ["group_id" .= gidRaw, "user_id" .= pokerRaw]
      -- Retain pending intent until a dispatch actually builds context.
      for_ mIntent $ \st -> liftIO (noteBotActivity st pk.pkGroupId)
      -- Resolve a display name for group pokes.
      mName <-
        if isPrivateChat pk.pkGroupId
          then pure Nothing
          else do
            members <- fetchGroupMembers pk.pkGroupId
            pure (memberName <$> (find (\m -> m.mUserId == pk.pkUserId) =<< members))
      -- A poke is a real interaction that never went through ingest, so
      -- both parties may still lack a principal here.
      endpoint <- ensureQQEndpointFor pk.pkSelfId pk.pkGroupId
      let UserId selfRaw = pk.pkSelfId
      principals <-
        ensureEndpointPrincipals
          endpoint.endpointId
          ( Map.fromList
              [ (NativeUserId (tshow selfRaw), Just "max"),
                (NativeUserId (tshow pokerRaw), mName)
              ]
          )
      case ( Map.lookup (NativeUserId (tshow selfRaw)) principals,
             Map.lookup (NativeUserId (tshow pokerRaw)) principals
           ) of
        (Just selfPrincipal, Just pokerPrincipal) ->
          dispatchLLM mIntent OriginPoke $
            pokeTrigger pk selfPrincipal pokerPrincipal mName
        _ ->
          logAttention "poke: could not resolve principals" $
            object ["group_id" .= gidRaw, "user_id" .= pokerRaw]

-- | Pokes have no message: ID 0 is a sentinel excluded from quoting, reactions
-- and in-flight trigger tracking. 'OriginPoke' renders the empty body specially.
pokeTrigger :: PokeEvent -> PrincipalId -> PrincipalId -> Maybe T.Text -> DispatchMessage
pokeTrigger pk selfPrincipal senderPrincipal mName =
  DispatchMessage
    { selfId = pk.pkSelfId,
      groupId = pk.pkGroupId,
      userId = pk.pkUserId,
      selfPrincipalId = selfPrincipal,
      authorPrincipalId = senderPrincipal,
      canonicalId = CanonicalMessageId 0,
      body = Body [],
      replyTo = Nothing,
      senderDisplayName = mName,
      sourcePlatform = PlatformQQ,
      mentionPrincipals = Map.empty
    }

--------------------------------------------------------------------------------
-- LLM dispatch.

-- | Persist ping/pong as chat so the transcript includes both sides.
sendPong ::
  (Outbound :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  DispatchMessage ->
  Eff es ()
sendPong gm = do
  let UserId fromRaw = gm.userId
      GroupId gidRaw = gm.groupId
      display = fromMaybe (tshow fromRaw) gm.senderDisplayName
  resolved <-
    if isPrivateChat gm.groupId
      then pure Map.empty
      else resolveMentionIdentities gidRaw [gm.authorPrincipalId]
  let mention =
        [ NMention (MentionIdentity identity) display
        | Just identity <- [Map.lookup gm.authorPrincipalId resolved]
        ]
  sendAndRecord KindChat DeliverConversation gm.groupId (Body (mention <> [NText " pong"])) (Just gm.canonicalId)
  logInfo "replied pong" $ object ["to" .= fromRaw, "group_id" .= gidRaw]

dispatchProactive ::
  ( Blob :> es,
    Log :> es,
    WithConnection :> es,
    PlatformQuery :> es,
    Outbound :> es,
    Agent :> es,
    Concurrent :> es,
    Reader BotEnv :> es,
    Reader ModelCatalog :> es,
    IOE :> es
  ) =>
  Maybe IntentState ->
  [DispatchMessage] ->
  Eff es ()
dispatchProactive mIntent batch = case unsnoc batch of
  Nothing -> pure ()
  Just (_, trigger) ->
    dispatchLLM mIntent OriginProactive trigger
