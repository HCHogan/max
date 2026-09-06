{-# LANGUAGE TypeFamilies #-}

-- | Platform reads. Results are domain data; callers cannot submit an Action,
-- inspect a raw RPC envelope, send content, poke or administer the account.
module Max.Effects.PlatformQuery
  ( PlatformQuery,
    runPlatformQuery,
    queryGroupMeta,
    queryGroupMembers,
    queryForward,
    queryGroupFileUrl,
  )
where

import Data.Aeson (Value, withArray, withObject, (.!=), (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import Data.Bifunctor (first)
import Data.Foldable (toList)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.Platform.Failure (PlatformFailure (..))
import Max.Platform.Roster (GroupMember (..), GroupMeta (..))
import Max.Platform.Rpc (PlatformRouter, callPlatform)
import OneBot.Action (Action (GetForwardMsg, GetGroupFileUrl, GetGroupInfo, GetGroupMemberList))
import OneBot.Types (GroupId)

data PlatformQuery :: Effect where
  QueryGroupMeta :: GroupId -> PlatformQuery m (Either PlatformFailure GroupMeta)
  QueryGroupMembers :: GroupId -> PlatformQuery m (Either PlatformFailure [GroupMember])
  -- The forward payload is adapter data decoded by the forward-ingest worker.
  QueryForward :: Text -> PlatformQuery m (Either PlatformFailure Value)
  QueryGroupFileUrl :: GroupId -> Text -> PlatformQuery m (Either PlatformFailure Text)

type instance DispatchOf PlatformQuery = Dynamic

runPlatformQuery :: (WithConnection :> es, IOE :> es) => PlatformRouter es -> Eff (PlatformQuery : es) a -> Eff es a
runPlatformQuery router = interpret $ \_ -> \case
  QueryGroupMeta gid -> decode metaParser <$> callPlatform router (GetGroupInfo gid) 10000
  QueryGroupMembers gid -> decode membersParser <$> callPlatform router (GetGroupMemberList gid) 10000
  QueryForward forwardId -> callPlatform router (GetForwardMsg forwardId) 30000
  QueryGroupFileUrl gid fileId -> decode (withObject "GroupFileUrl" (.: "url")) <$> callPlatform router (GetGroupFileUrl gid fileId) 30000
  where
    decode :: (Value -> Parser b) -> Either PlatformFailure Value -> Either PlatformFailure b
    decode parser value = value >>= first (PlatformInvalidResponse . T.pack) . parseEither parser
    metaParser = withObject "group info" $ \o -> GroupMeta <$> o .: "group_name" <*> o .:? "member_count"
    membersParser = withArray "member list" (fmap toList . traverse memberParser)
    memberParser = withObject "member" $ \o -> GroupMember <$> o .: "user_id" <*> o .:? "nickname" <*> o .:? "card" <*> o .:? "role" .!= "member" <*> o .:? "title"

queryGroupMeta :: (PlatformQuery :> es) => GroupId -> Eff es (Either PlatformFailure GroupMeta)
queryGroupMeta = send . QueryGroupMeta

queryGroupMembers :: (PlatformQuery :> es) => GroupId -> Eff es (Either PlatformFailure [GroupMember])
queryGroupMembers = send . QueryGroupMembers

queryForward :: (PlatformQuery :> es) => Text -> Eff es (Either PlatformFailure Value)
queryForward = send . QueryForward

queryGroupFileUrl :: (PlatformQuery :> es) => GroupId -> Text -> Eff es (Either PlatformFailure Text)
queryGroupFileUrl gid fileId = send (QueryGroupFileUrl gid fileId)
