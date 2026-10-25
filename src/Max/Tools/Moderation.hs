-- | Recall and mute in the current QQ group, as Max's own account.  Whether to
-- act is Max's call.  The host resolves canonical handles to QQ ids, refuses
-- up front what QQ's role rules would refuse anyway (with the reason, which
-- NapCat's bare retcode does not carry), and reports what QQ actually did.
module Max.Tools.Moderation (moderationToolsFor) where

import Data.Either (lefts, rights)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Max.Conversation.Roster (ConversationRoster (..), RosterIdentity (..))
import Max.Effects.ConversationQuery (ConversationQuery, readRoster)
import Max.Effects.PlatformModeration
  ( CopyOrigin (..),
    PlatformModeration,
    QQCopy,
    copyOrigin,
    messageCopies,
    moderatorAccount,
    muteMember,
    recallCopy,
  )
import Max.Effects.PlatformQuery (PlatformQuery)
import Max.Effects.Tools
  ( Tool,
    ToolFault (..),
    ToolOutcome (..),
    ToolRetryClass (..),
  )
import Max.Platform.Failure (PlatformFailure (..), renderPlatformFailure)
import Max.Platform.Types (CanonicalMessageId (..), Platform (PlatformQQ), PrincipalId (..))
import Max.Roster (GroupMember (..), fetchGroupMembers)
import Max.Tool.Arguments qualified as Args
import Max.Tool.Protocol (argumentTool)
import Max.ToolContext (ToolContext, toolGroupId)
import Max.Util (tshow)
import OneBot.Types (GroupId, UserId (..))
import Text.Read (readMaybe)

moderationToolsFor ::
  (PlatformModeration :> es, PlatformQuery :> es, ConversationQuery :> es, Log :> es) =>
  ToolContext ->
  [Tool es]
moderationToolsFor dc = [recallTool group, muteTool group]
  where
    group = toolGroupId dc

-- | QQ's longest mute.
maxMuteSeconds :: Int
maxMuteSeconds = 30 * 24 * 3600

recallTool ::
  (PlatformModeration :> es, PlatformQuery :> es, Log :> es) =>
  GroupId ->
  Tool es
recallTool group =
  argumentTool
    "recall_message"
    ( T.unwords
        [ "撤回本群的一条 QQ 消息。message_id 是行首 #<msgid> 里的数字。",
          "可以撤回你自己发的（一条回复拆成几条发出的会一起撤回）；你是管理员时也能撤回普通成员的，群主时还能撤回管理员的。",
          "撤不撤由你判断：刷屏、广告、违规内容，或有人请你撤回且理由正当时再用，用完简短说一声。",
          "非管理员只能撤回自己 2 分钟内的消息；NapCat 只记得最近几千条消息，太旧的撤不回。撤回后记录里会出现 [unsend#id]。"
        ]
    )
    (Args.required "message_id" (Args.int64 "行首 #<msgid> 里的数字"))
    $ \message -> withModerator group $ \self -> do
      copies <- messageCopies group (CanonicalMessageId message)
      if null copies
        then pure (refuse "本群在 QQ 上没有这条消息（id 不对，或者它不是 QQ 上的消息）")
        else do
          members <- fetchGroupMembers group
          case mapM_ (recallAllowed self members) copies of
            Left reason -> pure (refuse reason)
            Right () -> do
              results <- traverse recallCopy copies
              logInfo "moderation: recall" $
                object
                  [ "group" .= group,
                    "message_id" .= message,
                    "copies" .= length copies,
                    "failures" .= map renderPlatformFailure (lefts results)
                  ]
              pure (recallOutcome results)

-- | QQ's rule: anyone may recall their own messages, an administrator a
-- member's, the owner an administrator's.  Without a roster, QQ decides.
recallAllowed :: UserId -> Maybe [GroupMember] -> QQCopy -> Either Text ()
recallAllowed self members copy = case copyOrigin copy of
  DeliveredByMax -> Right ()
  ArrivedFrom (Just sender) | sender == self -> Right ()
  ArrivedFrom sender -> case members of
    Nothing -> Right ()
    Just roster -> case (roleIn roster self, roleIn roster =<< sender) of
      (Just "member", _) -> Left "你在本群不是管理员，只能撤回自己发的消息"
      (_, Just "owner") -> Left "群主的消息只有群主自己能撤回"
      (Just "admin", Just "admin") -> Left "管理员的消息只有群主能撤回"
      _ -> Right ()

recallOutcome :: [Either PlatformFailure ()] -> ToolOutcome
recallOutcome results = case (rights results, lefts results) of
  (_, []) -> ToolCommitted (object ["ok" .= True, "recalled" .= length results])
  ([], failure : _) -> platformFailure "撤回失败" recallCauses failure
  (done, failures@(failure : _)) ->
    ToolCommitted . object $
      [ "ok" .= False,
        "recalled" .= length done,
        "failed" .= length failures,
        "error" .= renderRejection recallCauses failure
      ]

recallCauses :: Text
recallCauses = "消息太旧 NapCat 已不认得、超过撤回时限、或权限不够"

muteTool ::
  (PlatformModeration :> es, PlatformQuery :> es, ConversationQuery :> es, Log :> es) =>
  GroupId ->
  Tool es
muteTool group =
  argumentTool
    "mute_member"
    ( T.unwords
        [ "禁言本群的一个 QQ 成员，或者解除禁言。member 是 [mention#<id>] 里的数字（即 group_members 的 id），",
          "seconds 是禁言秒数，最长 30 天（2592000），0 表示解除禁言。",
          "需要你是管理员；群主禁不了，管理员只有你是群主时才禁得了。",
          "禁不禁由你判断：刷屏、广告、恶意骚扰，或管理员请你禁言时再用，时长和情节相称，用完简短说一声。"
        ]
    )
    ( (,)
        <$> Args.required "member" (Args.int64 "[mention#<id>] 里的数字")
        <*> Args.required "seconds" (Args.int "禁言秒数，0 = 解除禁言，最长 2592000")
    )
    $ \(member, seconds) ->
      if seconds < 0 || seconds > maxMuteSeconds
        then pure (refuse ("seconds 要在 0 到 " <> tshow maxMuteSeconds <> " 之间"))
        else withModerator group $ \self -> do
          roster <- readRoster
          case qqAccountOf (PrincipalId member) roster of
            Nothing -> pure (refuse "这个人在本群没有 QQ 身份（id 不对，或者对方不在 QQ 这边）")
            Just target
              | target == self -> pure (refuse "不能禁言你自己")
              | otherwise -> do
                  members <- fetchGroupMembers group
                  case muteAllowed self target members of
                    Left reason -> pure (refuse reason)
                    Right () -> do
                      result <- muteMember group target seconds
                      logInfo "moderation: mute" $
                        object
                          [ "group" .= group,
                            "member" .= member,
                            "seconds" .= seconds,
                            "error" .= either (Just . renderPlatformFailure) (const Nothing) result
                          ]
                      pure $ case result of
                        Right () -> ToolCommitted (object ["ok" .= True, "seconds" .= seconds])
                        Left failure -> platformFailure (if seconds == 0 then "解除禁言失败" else "禁言失败") "权限不够，或对方已经不在群里" failure

-- | Only administrators mute, and only the owner mutes an administrator.
-- Without a roster, QQ decides.
muteAllowed :: UserId -> UserId -> Maybe [GroupMember] -> Either Text ()
muteAllowed self target = \case
  Nothing -> Right ()
  Just roster -> case (roleIn roster self, roleIn roster target) of
    (_, Nothing) -> Left "这个人已经不在群里了"
    (Just "member", _) -> Left "你在本群不是管理员，禁言不了别人"
    (_, Just "owner") -> Left "群主禁不了"
    (Just "admin", Just "admin") -> Left "管理员只有群主才能禁言"
    _ -> Right ()

qqAccountOf :: PrincipalId -> ConversationRoster -> Maybe UserId
qqAccountOf principal roster =
  fmap UserId . readMaybe . T.unpack . (.riNativeUserId)
    =<< find (\i -> i.riPrincipalId == principal && i.riPlatform == PlatformQQ) roster.crIdentities

roleIn :: [GroupMember] -> UserId -> Maybe Text
roleIn roster user = (.mRole) <$> find ((== user) . (.mUserId)) roster

withModerator :: (PlatformModeration :> es) => GroupId -> (UserId -> Eff es ToolOutcome) -> Eff es ToolOutcome
withModerator group act =
  moderatorAccount group >>= \case
    Nothing -> pure (refuse "撤回和禁言只支持 QQ 群")
    Just self -> act self

refuse :: Text -> ToolOutcome
refuse message = ToolFailedBeforeEffect (ToolFault "moderation_refused" message RetrySafe)

-- | NapCat answers a refusal with a bare retcode, so a rejection is reported
-- with its usual causes.  A lost answer may still have taken effect.
platformFailure :: Text -> Text -> PlatformFailure -> ToolOutcome
platformFailure action causes = \case
  failure@PlatformRejected {} -> ToolFailedBeforeEffect (ToolFault "platform_rejected" (action <> "：" <> renderRejection causes failure) RetrySafe)
  failure@PlatformTransportFailure {} -> unknown failure
  PlatformGenerationChanged -> unknown PlatformGenerationChanged
  failure -> ToolFailedBeforeEffect (ToolFault "platform_unavailable" (action <> "：" <> renderPlatformFailure failure) RetrySafe)
  where
    unknown failure = ToolOutcomeUnknown (ToolFault "platform_unknown" (action <> "：" <> renderPlatformFailure failure <> "，不确定 QQ 是否已经执行") RetryUnsafe)

renderRejection :: Text -> PlatformFailure -> Text
renderRejection causes failure@PlatformRejected {} = renderPlatformFailure failure <> "（常见原因：" <> causes <> "）"
renderRejection _ failure = renderPlatformFailure failure
