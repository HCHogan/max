-- |
-- Group metadata and member roster via NapCat: who's in the group,
-- who runs it, what it's called.  One member-list fetch feeds three
-- consumers: outbound @-mention validation (the member id set), the
-- system prompt's 群信息 lines (name / owner / admins), and the
-- @group_members@ tool (full roster on demand).
--
-- Avatars need no NapCat call at all — QQ serves them from public,
-- predictable URLs ('userAvatarUrl' / 'groupAvatarUrl').
module Max.Roster
  ( GroupMeta (..),
    GroupMember (..),
    fetchGroupMeta,
    fetchGroupMembers,
    memberName,
    renderGroupBrief,
    userAvatarUrl,
    groupAvatarUrl,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (Value, withArray, withObject, (.!=), (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Max.Effects.NapCat (NapCat, callAction)
import OneBot.Action (Action (GetGroupInfo, GetGroupMemberList), Response (..))
import OneBot.Types (GroupId (..), UserId (..))

data GroupMeta = GroupMeta
  { gmName :: !Text,
    gmMemberCount :: !(Maybe Int)
  }
  deriving stock (Show, Eq)

data GroupMember = GroupMember
  { mUserId :: !UserId,
    mNickname :: !(Maybe Text),
    -- | 群名片 — what the group actually sees; wins over nickname.
    mCard :: !(Maybe Text),
    -- | @owner@ / @admin@ / @member@.
    mRole :: !Text,
    -- | 专属头衔, when set.
    mTitle :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

-- | 群名片 > 昵称 > QQ号 — same preference order as the prompt's
-- display names.
memberName :: GroupMember -> Text
memberName m =
  fromMaybe (T.pack (show m.mUserId)) (nonBlank m.mCard <|> nonBlank m.mNickname)
  where
    nonBlank (Just t) | not (T.null (T.strip t)) = Just (T.strip t)
    nonBlank _ = Nothing

-- | Group name / member count.  'Nothing' on any RPC or parse
-- failure — callers degrade to not knowing, never to erroring.
fetchGroupMeta ::
  (NapCat :> es, Log :> es) =>
  GroupId ->
  Eff es (Maybe GroupMeta)
fetchGroupMeta gid = fetchParsed (GetGroupInfo gid) "group info" metaP
  where
    metaP = withObject "group info" $ \o ->
      GroupMeta
        <$> o .: "group_name"
        <*> o .:? "member_count"

-- | Full member list, NapCat order.  'Nothing' on failure.
fetchGroupMembers ::
  (NapCat :> es, Log :> es) =>
  GroupId ->
  Eff es (Maybe [GroupMember])
fetchGroupMembers gid =
  fetchParsed (GetGroupMemberList gid) "member list" membersP
  where
    membersP =
      withArray "member list" $
        fmap toList . traverse memberP
    memberP = withObject "member" $ \o ->
      GroupMember
        <$> o .: "user_id"
        <*> o .:? "nickname"
        <*> o .:? "card"
        <*> o .:? "role" .!= "member"
        <*> o .:? "title"

-- | Shared call/retcode/parse skeleton for the two lookups.
fetchParsed ::
  (NapCat :> es, Log :> es) =>
  Action ->
  Text -> -- label for log lines
  (Value -> Parser a) ->
  Eff es (Maybe a)
fetchParsed action label parser =
  callAction action 10000 >>= \case
    Left err -> do
      logAttention (label <> " fetch failed") $ object ["error" .= err]
      pure Nothing
    Right (Response _ rc payload _)
      | rc /= 0 -> do
          logAttention (label <> " retcode bad") $ object ["retcode" .= rc]
          pure Nothing
      | otherwise -> case parseEither parser payload of
          Left e -> do
            logAttention (label <> " parse failed") $
              object ["error" .= T.pack e]
            pure Nothing
          Right x -> pure (Just x)

-- | The 群信息 lines for the system prompt's [当前环境] block
-- (un-indented; the renderer prefixes).  Group name and 群主/管理员
-- names+QQ号 — the compact always-useful subset; the full roster
-- stays behind the @group_members@ tool.
renderGroupBrief :: Maybe GroupMeta -> Maybe [GroupMember] -> [Text]
renderGroupBrief mMeta mMembers =
  concat
    [ [ "群名："
          <> meta.gmName
          <> maybe "" (\c -> "（" <> T.pack (show c) <> "人）") meta.gmMemberCount
      | Just meta <- [mMeta]
      ],
      [ "群主："
          <> listNames owners
          <> (if null admins then "" else "；管理员：" <> listNames admins)
      | Just members <- [mMembers],
        let owners = [m | m <- members, m.mRole == "owner"]
            admins = [m | m <- members, m.mRole == "admin"],
        not (null owners && null admins)
      ]
    ]
  where
    listNames ms =
      T.intercalate
        "、"
        [memberName m <> "(" <> T.pack (show m.mUserId) <> ")" | m <- ms]

-- | QQ avatar endpoints are public and predictable; no API needed.
userAvatarUrl :: UserId -> Text
userAvatarUrl (UserId uid) =
  "https://q.qlogo.cn/headimg_dl?dst_uin=" <> T.pack (show uid) <> "&spec=640"

groupAvatarUrl :: GroupId -> Text
groupAvatarUrl (GroupId gid) =
  "https://p.qlogo.cn/gh/" <> g <> "/" <> g <> "/640"
  where
    g = T.pack (show gid)
