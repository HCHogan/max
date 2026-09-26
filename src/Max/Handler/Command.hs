module Max.Handler.Command
  ( routeTaskInput,
    dispatchCommand,
  )
where

import Control.Concurrent.STM (readTVarIO)
import Data.Aeson (ToJSON (toJSON))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Concurrent.Async (Concurrent)
import Effectful.Log
  ( Log,
    MonadLog (localDomain),
    logInfo,
    object,
    (.=),
  )
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Browser.Profile (browserCommandOnce)
import Max.Command.Dispatcher (DispatchResult (..))
import Max.Command.Dispatcher qualified as CmdDispatch
import Max.Command.Parser (parseCommand)
import Max.Command.Permission
  ( PermTier (..),
    requiredCapability,
    tierSatisfied,
  )
import Max.Command.Types (Command (..))
import Max.Dispatch
  ( DispatchMessage (..),
    dispatchTextWithoutSelf,
    stripDispatchVerb,
  )
import Max.Effects.Agent (Agent)
import Max.Effects.Blob (Blob)
import Max.Effects.Outbound
  ( Outbound,
    OutboundDeliveryScope (..),
    OutboundRequest (..),
    sendRecorded,
    wasPublished,
  )
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Env (BotEnv (..))
import Max.Handler.Access (effectiveTier)
import Max.Handler.Output (replyText)
import Max.Handler.Reaction
  ( ackFaceId,
    deniedFaceId,
    queueQQReaction,
  )
import Max.IR (Body (Body), Node (NText))
import Max.Intent (IntentState)
import Max.Jobs qualified as Jobs
import Max.MessageKind (MessageKind (KindCommand))
import Max.ModelCatalog (ModelCatalog)
import Max.Platform.Types
  ( CanonicalMessageId (CanonicalMessageId),
    Platform (PlatformQQ),
  )
import Max.Prompt (TriggerOrigin (OriginDirect))
import Max.Roster (GroupMember (mUserId), fetchGroupMembers)
import Max.Session (loadSession)
import Max.Task.State (taskIsLive)
import Max.Task.Types (parseTaskHandle)
import Max.Text (encodeText)
import Max.Turn.Dispatch (dispatchLLM, dispatchLLMWith)
import Max.Turn.Start
  ( InputAdmission (StartSeparateTurn),
    TurnStart (NewTurn),
  )
import OneBot.Types (GroupId (..), UserId (UserId), isPrivateChat)

data JobChange = SteerJob | ReplaceJob | CancelJob

routeTaskInput ::
  (Log :> es, WithConnection :> es, PlatformQuery :> es, Outbound :> es, Reader BotEnv :> es, IOE :> es) =>
  DispatchMessage -> Eff es Bool
routeTaskInput message = do
  let body = T.strip (dispatchTextWithoutSelf message)
      -- !agent is the command's name; !task still works.
      pieces = case T.words body of
        "!agent" : rest -> "!task" : rest
        other -> other
      reply value = replyText message (T.take 16000 (encodeText value)) >> pure True
      mutate identifier operation note = do
        env :: BotEnv <- ask
        tier <- effectiveTier env message.groupId message
        outcome <- liftIO $ case operation of
          SteerJob -> Jobs.steerJob env.beJobs message.groupId message.authorPrincipalId (Just message.canonicalId) identifier note
          ReplaceJob -> Jobs.replaceJob env.beJobs message.groupId message.authorPrincipalId (tierSatisfied TierGroupAdmin tier) identifier note
          CancelJob -> Jobs.cancelJob env.beJobs message.groupId message.authorPrincipalId (tierSatisfied TierGroupAdmin tier) identifier note
        reply (either (\detail -> object ["error" .= detail]) (const (object ["accepted" .= True])) outcome)
      readJobs action = do
        env :: BotEnv <- ask
        liftIO (action env.beJobs) >>= reply
      steerLive identifier note = do
        env :: BotEnv <- ask
        live <- liftIO (maybe False (taskIsLive . (.status)) <$> Jobs.lookupJob env.beJobs message.groupId identifier)
        if live then mutate identifier SteerJob note else pure False
  case pieces of
    "!browser" : arguments -> do
      env :: BotEnv <- ask
      browserCommandOnce env.beJobs env.beBrowsers message.groupId message.authorPrincipalId message.canonicalId arguments >>= reply
    ["!task", "list"] -> readJobs (\jobs -> toJSON <$> Jobs.listJobs jobs message.groupId)
    ["!task", "status", handle] | Just identifier <- parseTaskHandle handle -> readJobs (\jobs -> toJSON <$> Jobs.lookupJob jobs message.groupId identifier)
    "!task" : "replace" : handle : note
      | Just identifier <- parseTaskHandle handle ->
          mutate identifier ReplaceJob (T.unwords note)
    "!task" : operation : handle : note
      | operation `elem` ["steer", "cancel"],
        Just identifier <- parseTaskHandle handle ->
          mutate identifier (if operation == "steer" then SteerJob else CancelJob) (if null note && operation == "cancel" then "cancelled by user" else T.unwords note)
    "!task" : _ -> replyText message "用法：!agent list | status agent#N | steer agent#N 内容 | cancel agent#N [原因] | replace agent#N 新目标" >> pure True
    command : handle : note
      | command `elem` ["!feedback", "!fb"],
        Just identifier <- parseTaskHandle handle ->
          mutate identifier SteerJob (T.unwords note)
    -- A literal live agent handle remains explicit steering. Quoted replies,
    -- including !fb replies, enter the root node's normal reply routing.
    handle : note
      | "agent#" `T.isPrefixOf` handle,
        not (null note),
        Just identifier <- parseTaskHandle handle ->
          steerLive identifier (T.unwords note)
    _ -> pure False

--------------------------------------------------------------------------------
-- Commands.

dispatchCommand ::
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
  T.Text ->
  Eff es ()
dispatchCommand mIntent gm body = localDomain "cmd" $ do
  case parseCommand body of
    Left err -> replyText gm ("命令解析失败:\n" <> err)
    Right Nothing -> pure () -- shouldn't reach here; classify already filtered
    Right (Just cmd) -> do
      env :: BotEnv <- ask
      let sourcePlatform = gm.sourcePlatform
      targetGid <- resolveAdminTarget env gm cmd
      effTier <- effectiveTier env targetGid gm
      let allowed = checkCmdPermission effTier cmd
      if not allowed
        then do
          let UserId uidRaw = gm.userId
          logInfo "command denied" $
            object ["cmd" .= T.pack (show cmd), "user_id" .= uidRaw]
          if isForeignSource sourcePlatform
            then replyText gm "没有权限"
            else
              -- Same NO face as [silence:NO]: visibly refused, zero noise.
              queueQQReaction gm.groupId gm.canonicalId deniedFaceId True
        else dispatchAllowed env targetGid sourcePlatform cmd
  where
    isForeignSource = (/= PlatformQQ)

    dispatchAllowed env targetGid sourcePlatform cmd = do
      t <- loadSession env.beSessions env.beDefaultModel targetGid
      logInfo "command" $ object ["cmd" .= T.pack (show cmd)]
      let replyTarget = (\(CanonicalMessageId target) -> target) <$> gm.replyTo
      result <- CmdDispatch.execute t targetGid gm.userId gm.authorPrincipalId replyTarget cmd
      case result of
        -- QQ group commands reply by DM, falling back to the group on failure.
        -- Private chats and other platforms reply inline.
        ReplyText reply
          | isPrivateChat gm.groupId || isForeignSource sourcePlatform -> replyText gm reply
          | otherwise -> deliverPrivate reply
        -- Deliberately group-audience output (e.g. !version).
        ReplyPublicText reply -> replyText gm reply
        -- Pure acknowledgement: an OK reaction on the command message
        -- beats another line of chat noise.
        ReplyAck
          | isForeignSource sourcePlatform -> replyText gm "OK"
          | otherwise -> queueQQReaction gm.groupId gm.canonicalId ackFaceId True
        SideQuestion askBody -> do
          logInfo "btw: side question" $
            object ["len" .= T.length askBody]
          -- Strip only the command verb, preserving reply relations and attachments.
          dispatchLLMWith (NewTurn StartSeparateTurn) mIntent OriginDirect (stripDispatchVerb gm)
        FeedbackNote _ ->
          dispatchLLM mIntent OriginDirect gm

    -- Record private command output in the DM conversation.
    deliverPrivate reply = do
      let GroupId gidRaw = gm.groupId
          UserId uidRaw = gm.userId
          header = "（群 " <> T.pack (show gidRaw) <> " 的命令结果）\n"
      outcome <-
        sendRecorded
          OutboundRequest
            { orKind = KindCommand,
              orGroupId = GroupId (negate uidRaw),
              orBody = Body [NText (header <> reply)],
              orReplyTo = Nothing,
              orDeliveryScope = DeliverConversation,
              orTurnOutput = Nothing,
              orMonitorFireId = Nothing
            }
      if wasPublished outcome
        then queueQQReaction gm.groupId gm.canonicalId ackFaceId True
        else do
          logInfo "cmd: private delivery failed, group fallback" $
            object ["user_id" .= uidRaw, "group_id" .= gidRaw]
          replyText gm (reply <> "\n\n（加我好友后，这类结果会私聊发你，不刷群）")

-- | Private commands use the selected @!use@ group, except @!use@ itself.
-- Owners may select any group; other callers must belong to the target group.
resolveAdminTarget ::
  (PlatformQuery :> es, Log :> es, IOE :> es) =>
  BotEnv ->
  DispatchMessage ->
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
              if any (\m -> m.mUserId == gm.userId) (fromMaybe [] members)
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

-- | May the sender run this command against the target group?  The tier the
-- command declares against the tier the sender has.  Commands without a
-- capability are open to all.
checkCmdPermission :: PermTier -> Command -> Bool
checkCmdPermission effTier cmd = case requiredCapability cmd of
  Nothing -> True
  Just (_, tier) -> tierSatisfied tier effTier
