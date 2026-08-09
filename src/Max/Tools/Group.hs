-- |
-- On-demand group roster for the agent: the full member list is too
-- big for the system prompt (the [environment] block only carries 群名 +
-- 群主/管理员 — see "Max.Roster"), so the rest sits behind a tool the
-- model calls when it actually needs to know who's in the group or
-- what someone's avatar looks like.
module Max.Tools.Group
  ( groupToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Base64 qualified as B64
import Data.Int (Int64)
import Data.Function (on)
import Data.List (find, groupBy, sortOn)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log
import Max.Effects.Http (Http, getBytesQqCompatible)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.PlatformApi (PlatformApi)
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, queueInlineMedia)
import Max.Effects.Tools (Tool (..))
import Max.IR (sniffMediaMime)
import Max.Platform.Store (ConversationRoster (..), RosterIdentity (..), conversationRoster)
import Max.Platform.Types (Platform (..), PrincipalId (..), renderPlatform)
import Max.Roster
  ( GroupMember (..),
    GroupMeta (..),
    fetchGroupMembers,
    fetchGroupMeta,
    groupAvatarUrl,
    memberName,
    userAvatarUrl,
  )
import Max.ToolContext (ToolContext, toolGroupId, toolMultimodal)
import Max.Tools.Schema (boolParam, integerParam, stringParam, toolObject)
import Max.Util (tshow)
import OneBot.Types (GroupId (..), UserId (..), isPrivateChat)

groupToolsFor ::
  (PlatformApi :> es, Http :> es, Log :> es, ToolOutput :> es, WithConnection :> es, IOE :> es) =>
  ToolContext ->
  [Tool es]
groupToolsFor dc =
  [membersTool (toolGroupId dc) | not private]
    <> [avatarTool dc | toolMultimodal dc]
  where
    private = isPrivateChat (toolGroupId dc)

-- | Cap on members returned per call; @offset@ pages through the rest.
pageSize :: Int
pageSize = 80

-- | One row of the answer, before it becomes JSON.  The ledger supplies the
-- principal — the only id the model can act on (ADR 004) — and a platform
-- roster, where one exists, supplies everything QQ knows and the ledger
-- cannot: role, title, and the members who have never spoken.
data RosterEntry = RosterEntry
  { reId :: !(Maybe Int64),
    reName :: !Text,
    reRole :: !(Maybe Text),
    reTitle :: !(Maybe Text),
    reAccounts :: ![(Platform, Text)],
    reNatives :: ![Text],
    rePlatforms :: ![Text]
  }

membersTool ::
  (PlatformApi :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  GroupId ->
  Tool es
membersTool gid@(GroupId legacy) =
  Tool
    { toolName = "group_members",
      toolDescription =
        "查询本会话的成员列表：每个成员的 id、名字（群名片优先）、所在平台，\
        \QQ 群还带 role（owner=群主 / admin=管理员 / member=普通成员）和专属头衔。\
        \id 就是 [mention#<id>] 里的那个数字，指的是人不是账号。\
        \id 为 null 表示这人还没在本会话说过话，认得出但 @ 不了。\
        \可选 query 按名字或 id 过滤；成员太多时用 offset 翻页。",
      toolSchema =
        toolObject
          [ ("query", stringParam "按名字/群名片/id 子串过滤（可选）"),
            ("offset", integerParam "跳过前多少个匹配结果，翻页用（默认 0）")
          ]
          [],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mQuery, offset) -> do
          -- The ledger answers on every platform; a QQ member list is an
          -- enrichment on top of it, not the source.  This tool used to *be*
          -- the OneBot call, so a Matrix or iMessage conversation got
          -- "成员列表获取失败" — the model was told nobody was in the room.
          roster <- conversationRoster legacy
          let qq = PlatformQQ `elem` roster.crPlatforms
          members <- if qq then fetchGroupMembers gid else pure Nothing
          meta <- if qq then fetchGroupMeta gid else pure Nothing
          let entries = mergeRoster roster.crIdentities members
              matched = filter (matches mQuery) (sortOn entryRank entries)
              page = take pageSize (drop offset matched)
          if null entries
            then pure (Left "本会话还没有已知成员（没人说过话，平台也没给出名单）")
            else
              pure . Right . object $
                [ "member_count" .= length entries,
                  "total_matched" .= length matched,
                  "offset" .= offset,
                  "members" .= map entryJson page
                ]
                  <> ["group_name" .= name | Just name <- [(.gmName) <$> meta]]
                  <> ( if qq
                         then
                           [ "group_avatar_url" .= groupAvatarUrl gid,
                             "member_avatar_url_pattern"
                               .= ("https://q.qlogo.cn/headimg_dl?dst_uin=<qq>&spec=640" :: Text)
                           ]
                         else []
                     )
    }
  where
    parseArgs :: Object -> Parser (Maybe Text, Int)
    parseArgs o = (,) <$> o .:? "query" <*> o .:? "offset" .!= 0

    -- Owner first, admins next; everyone the ledger alone knows sorts last
    -- because it has no role to rank them by.
    entryRank :: RosterEntry -> Int
    entryRank e = case e.reRole of
      Just "owner" -> 0
      Just "admin" -> 1
      _ -> 2

    matches Nothing _ = True
    matches (Just q) e =
      let q' = T.toLower (T.strip q)
       in q' `T.isInfixOf` T.toLower e.reName
            || any ((q' `T.isInfixOf`) . tshow) e.reId
            || q' `T.isInfixOf` T.toLower (T.intercalate " " e.reNatives)

    -- Per-member avatar URLs would bloat an 80-entry page for no
    -- information — the response-level pattern covers them all.
    entryJson e =
      object $
        [ "id" .= e.reId,
          "name" .= e.reName,
          "platforms" .= e.rePlatforms
        ]
          <> maybe [] (\r -> ["role" .= r]) e.reRole
          <> maybe [] (\t -> ["title" .= t]) e.reTitle
          <> ["qq" .= native | Just native <- [qqNative e]]

    qqNative e = case [n | (p', n) <- e.reAccounts, p' == PlatformQQ] of
      native : _ -> Just native
      [] -> Nothing

    nonBlank (Just t) | not (T.null (T.strip t)) = Just (T.strip t)
    nonBlank _ = Nothing

    -- Union of the two answers, keyed on the native id — the only thing both
    -- sides carry.  A member the ledger has never seen is still listed:
    -- named, ranked, and explicitly unaddressable (id = null) rather than
    -- quietly missing.  A principal linked across two accounts appears once.
    mergeRoster identities members =
      let people =
            [ RosterEntry
                { reId = Just principal,
                  reName = ledgerName principal group,
                  reRole = Nothing,
                  reTitle = Nothing,
                  reAccounts = [(i.riPlatform, i.riNativeUserId) | i <- group],
                  reNatives = [i.riNativeUserId | i <- group],
                  rePlatforms = map (renderPlatform . (.riPlatform)) group
                }
            | group@(first : _) <- groupBy ((==) `on` (.riPrincipalId)) identities,
              let PrincipalId principal = first.riPrincipalId
            ]
          claimed = concatMap (.reNatives) people
       in case members of
            Nothing -> people
            Just native ->
              [ enrich person native | person <- people ]
                <> [ RosterEntry
                       { reId = Nothing,
                         reName = memberName m,
                         reRole = Just m.mRole,
                         reTitle = nonBlank m.mTitle,
                         reAccounts = [(PlatformQQ, nativeText m)],
                         reNatives = [nativeText m],
                         rePlatforms = ["qq"]
                       }
                   | m <- native,
                     nativeText m `notElem` claimed
                   ]

    -- A person the ledger already knows keeps their principal and gains
    -- whatever QQ can add about them.
    enrich person native = case find (\m -> nativeText m `elem` person.reNatives) native of
      Nothing -> person
      Just m ->
        person
          { reName = memberName m,
            reRole = Just m.mRole,
            reTitle = nonBlank m.mTitle
          }

    ledgerName principal group =
      fromMaybe (tshow principal) (listToMaybe (mapMaybe (nonBlank . (.riDisplayName)) group))

    nativeText m = let UserId uid = m.mUserId in tshow uid

--------------------------------------------------------------------------------
-- view_avatar — actually look at one.

-- | qlogo serves avatars re-encoded well under this; anything bigger
-- means something unexpected came back.
maxAvatarBytes :: Int
maxAvatarBytes = 2 * 1024 * 1024

avatarTool ::
  (PlatformApi :> es, Http :> es, Log :> es, ToolOutput :> es) =>
  ToolContext ->
  Tool es
avatarTool dc =
  Tool
    { toolName = "view_avatar",
      toolDescription =
        "查看头像：传 qq 看该用户的头像，传 group=true 看本群群头像。\
        \图片会附在下一条消息里给你看。每次任务最多看 8 张。",
      toolSchema =
        toolObject
          [ ("qq", integerParam "要看头像的 QQ号"),
            ("group", boolParam "true = 看群头像（与 qq 二选一）")
          ]
          [],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (Nothing, False) -> pure $ Left "要么传 qq，要么传 group=true"
        Right (_, True)
          | isPrivateChat (toolGroupId dc) -> pure $ Left "私聊没有群头像"
          | otherwise ->
              fetchAndQueue (groupAvatarUrl (toolGroupId dc)) "[group avatar]:"
        Right (Just qq, _) -> do
          -- Best-effort name for the label so the model can tell whose
          -- face it is looking at when several avatars pile up.
          who <-
            if isPrivateChat (toolGroupId dc)
              then pure Nothing
              else do
                members <- fetchGroupMembers (toolGroupId dc)
                pure $ do
                  ms <- members
                  m <- lookupMember (UserId qq) ms
                  Just (memberName m)
          let label =
                "[avatar] "
                  <> fromMaybe (T.pack (show qq)) who
                  <> "("
                  <> T.pack (show qq)
                  <> "):"
          fetchAndQueue (userAvatarUrl (UserId qq)) label
    }
  where
    parseArgs :: Object -> Parser (Maybe Int64, Bool)
    parseArgs o = (,) <$> o .:? "qq" <*> o .:? "group" .!= False

    lookupMember uid = find (\m -> m.mUserId == uid)

-- | Download, sniff the real image type (qlogo's @Content-Type@ is
-- not reliable), queue as an inline data URL for the post-round
-- injection.
fetchAndQueue ::
  (Http :> es, Log :> es, ToolOutput :> es) =>
  Text -> -- avatar url
  Text -> -- label for the injected image block
  Eff es (Either Text Value)
fetchAndQueue url label =
  getBytesQqCompatible url maxAvatarBytes >>= \case
    Left err -> do
      logAttention "view_avatar: fetch failed" $
        object ["url" .= url, "error" .= err]
      pure $ Left ("头像下载失败: " <> err)
    Right (bytes, mime) -> do
      let mime' = fromMaybe (defaultMime mime) (sniffMediaMime bytes)
          b64 = TE.decodeUtf8 (B64.encode bytes)
          dataUrl = "data:" <> mime' <> ";base64," <> b64
      ok <- queueInlineMedia (InlineMedia label dataUrl)
      pure $
        if ok
          then Right (object ["attached" .= True, "note" .= ("头像已附在下一条消息里" :: Text)])
          else Left "本次任务的图片配额（8 张）已用完"
  where
    defaultMime m
      | "image/" `T.isPrefixOf` m = m
      | otherwise = "image/jpeg"

