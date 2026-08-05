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
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.Int (Int64)
import Data.List (find, sortOn)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log
import Max.Effects.Http (Http, getBytesQqCompatible)
import Max.Effects.PlatformApi (PlatformApi)
import Max.Effects.ToolOutput (InlineMedia (..), ToolOutput, queueInlineMedia)
import Max.Effects.Tools (Tool (..))
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
import OneBot.Types (GroupId, UserId (..), isPrivateChat)

groupToolsFor ::
  (PlatformApi :> es, Http :> es, Log :> es, ToolOutput :> es) =>
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

membersTool :: (PlatformApi :> es, Log :> es) => GroupId -> Tool es
membersTool gid =
  Tool
    { toolName = "group_members",
      toolDescription =
        "查询本群的群信息和成员列表：每个成员的 QQ号、名字（群名片优先）、role\
        \（owner=群主 / admin=管理员 / member=普通成员）、专属头衔。响应还带群名、\
        \人数和头像 URL（群头像 + 成员头像的 URL 规则，可直接引用或发给别人）。\
        \可选 query 按名字或 QQ号 过滤；成员太多时用 offset 翻页。",
      toolSchema =
        toolObject
          [ ("query", stringParam "按名字/群名片/QQ号 子串过滤（可选）"),
            ("offset", integerParam "跳过前多少个匹配结果，翻页用（默认 0）")
          ]
          [],
      toolRun = \args -> case parseEither (withObject "args" parseArgs) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (mQuery, offset) ->
          fetchGroupMembers gid >>= \case
            Nothing -> pure (Left "成员列表获取失败（NapCat 未响应？）")
            Just members -> do
              meta <- fetchGroupMeta gid
              let matched = filter (matches mQuery) (sortOn roleRank members)
                  page = take pageSize (drop offset matched)
              pure . Right $
                object
                  [ "group_name" .= maybe Null (toJSON . (.gmName)) meta,
                    "member_count"
                      .= fromMaybe (length members) (meta >>= (.gmMemberCount)),
                    "group_avatar_url" .= groupAvatarUrl gid,
                    "member_avatar_url_pattern"
                      .= ("https://q.qlogo.cn/headimg_dl?dst_uin=<QQ号>&spec=640" :: Text),
                    "total_matched" .= length matched,
                    "offset" .= offset,
                    "members" .= map memberJson page
                  ]
    }
  where
    parseArgs :: Object -> Parser (Maybe Text, Int)
    parseArgs o = (,) <$> o .:? "query" <*> o .:? "offset" .!= 0

    -- Owner first, admins next — the entries most queries are after.
    roleRank :: GroupMember -> Int
    roleRank m = case m.mRole of
      "owner" -> 0
      "admin" -> 1
      _ -> 2

    matches Nothing _ = True
    matches (Just q) m =
      let q' = T.toLower (T.strip q)
          UserId uid = m.mUserId
       in q' `T.isInfixOf` T.toLower (memberName m)
            || q' `T.isInfixOf` T.toLower (fromMaybe "" m.mNickname)
            || q' `T.isInfixOf` T.pack (show uid)

    -- Per-member avatar URLs would bloat an 80-entry page for no
    -- information — the response-level pattern covers them all.
    memberJson m =
      object $
        [ "qq" .= m.mUserId,
          "name" .= memberName m,
          "role" .= m.mRole
        ]
          <> maybe [] (\t -> ["title" .= t]) (nonBlank m.mTitle)

    nonBlank (Just t) | not (T.null (T.strip t)) = Just (T.strip t)
    nonBlank _ = Nothing

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
      let mime' = fromMaybe (defaultMime mime) (sniffImageMime bytes)
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

-- | Magic-byte sniffing for the formats qlogo actually serves.
sniffImageMime :: ByteString -> Maybe Text
sniffImageMime bs
  | BS.take 3 bs == "\xFF\xD8\xFF" = Just "image/jpeg"
  | BS.take 8 bs == "\x89PNG\r\n\SUB\n" = Just "image/png"
  | BS.take 4 bs == "GIF8" = Just "image/gif"
  | BS.take 4 bs == "RIFF" && BS.take 4 (BS.drop 8 bs) == "WEBP" = Just "image/webp"
  | otherwise = Nothing
