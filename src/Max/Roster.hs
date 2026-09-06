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
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Max.Effects.PlatformQuery (PlatformQuery, queryGroupMembers, queryGroupMeta)
import Max.Platform.Failure (PlatformFailure, renderPlatformFailure)
import Max.Platform.Roster (GroupMember (..), GroupMeta (..))
import OneBot.Types (GroupId (..), UserId (..))

-- | 群名片 > 昵称 > QQ号 — same preference order as the prompt's
-- display names.
memberName :: GroupMember -> Text
memberName m =
  fromMaybe (T.pack (show m.mUserId)) (nonBlank m.mCard <|> nonBlank m.mNickname)
  where
    nonBlank (Just t) | not (T.null (T.strip t)) = Just (T.strip t)
    nonBlank _ = Nothing

-- | Callers degrade to an unknown roster on failure, with one diagnostic at
-- this presentation boundary. They never acquire platform write capability.
fetchGroupMeta :: (PlatformQuery :> es, Log :> es) => GroupId -> Eff es (Maybe GroupMeta)
fetchGroupMeta gid = fetchResult "group info" (queryGroupMeta gid)

fetchGroupMembers :: (PlatformQuery :> es, Log :> es) => GroupId -> Eff es (Maybe [GroupMember])
fetchGroupMembers gid = fetchResult "member list" (queryGroupMembers gid)

fetchResult :: (Log :> es) => Text -> Eff es (Either PlatformFailure a) -> Eff es (Maybe a)
fetchResult label action =
  action >>= \case
    Left failure -> do
      logAttention (label <> " fetch failed") $ object ["error" .= renderPlatformFailure failure]
      pure Nothing
    Right value -> pure (Just value)

-- | The 群信息 lines for the system prompt's [environment] block
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
