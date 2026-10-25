{-# LANGUAGE TypeFamilies #-}

-- | Group moderation as Max's own QQ account. A message is named by canonical
-- id and the interpreter finds its QQ copies inside the caller's conversation;
-- a copy cannot be minted for any other one.
module Max.Effects.PlatformModeration
  ( PlatformModeration,
    runPlatformModeration,
    moderatorAccount,
    QQCopy,
    CopyOrigin (..),
    copyOrigin,
    messageCopies,
    recallCopy,
    muteMember,
  )
where

import Data.Functor (void)
import Data.Int (Int64)
import Data.List (nubBy)
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.Platform.Failure (PlatformFailure)
import Max.Platform.Rpc (PlatformRouter, callPlatform)
import Max.Platform.Store.Endpoint (qqGroupAccountForLegacyConversation)
import Max.Platform.Store.Relation (qqCopiesInConversation)
import Max.Platform.Types (CanonicalMessageId)
import OneBot.Action (Action (DeleteMsg, SetGroupBan))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Text.Read (readMaybe)

-- | One QQ message a canonical message appears as.
data QQCopy = QQCopy
  { qcGroup :: !GroupId,
    qcMessage :: !MessageId,
    qcOrigin :: !CopyOrigin
  }
  deriving stock (Eq, Show)

-- | Whether Max put the copy there or it arrived from a sender (unknown when
-- the event carries no identity).
data CopyOrigin = DeliveredByMax | ArrivedFrom !(Maybe UserId)
  deriving stock (Eq, Show)

copyOrigin :: QQCopy -> CopyOrigin
copyOrigin = (.qcOrigin)

data PlatformModeration :: Effect where
  -- | Max's QQ account in the group, or 'Nothing' when the conversation has
  -- no QQ group endpoint to moderate.
  ModeratorAccount :: GroupId -> PlatformModeration m (Maybe UserId)
  MessageCopies :: GroupId -> CanonicalMessageId -> PlatformModeration m [QQCopy]
  RecallCopy :: QQCopy -> PlatformModeration m (Either PlatformFailure ())
  MuteMember :: GroupId -> UserId -> Int -> PlatformModeration m (Either PlatformFailure ())

type instance DispatchOf PlatformModeration = Dynamic

runPlatformModeration :: (WithConnection :> es, IOE :> es) => PlatformRouter es -> Eff (PlatformModeration : es) a -> Eff es a
runPlatformModeration router = interpret $ \_ -> \case
  ModeratorAccount (GroupId legacy) -> (fmap UserId . readId =<<) <$> qqGroupAccountForLegacyConversation legacy
  MessageCopies group@(GroupId legacy) canonical ->
    distinct . mapMaybe (copy group) <$> qqCopiesInConversation legacy canonical
  RecallCopy target -> void <$> callPlatform router (DeleteMsg target.qcGroup target.qcMessage) 10000
  MuteMember group user seconds -> void <$> callPlatform router (SetGroupBan group user seconds) 10000
  where
    copy group (native, delivered, sender) = do
      message <- readId native
      pure (QQCopy group (MessageId message) (if delivered then DeliveredByMax else ArrivedFrom (UserId <$> (readId =<< sender))))
    readId :: T.Text -> Maybe Int64
    readId = readMaybe . T.unpack
    -- An echoed delivery is listed both as a delivery and as an arrival;
    -- the delivery wins, since Max sent it.
    distinct copies =
      nubBy (\a b -> a.qcMessage == b.qcMessage) $
        [c | c <- copies, c.qcOrigin == DeliveredByMax] <> [c | c <- copies, c.qcOrigin /= DeliveredByMax]

moderatorAccount :: (PlatformModeration :> es) => GroupId -> Eff es (Maybe UserId)
moderatorAccount = send . ModeratorAccount

messageCopies :: (PlatformModeration :> es) => GroupId -> CanonicalMessageId -> Eff es [QQCopy]
messageCopies group canonical = send (MessageCopies group canonical)

recallCopy :: (PlatformModeration :> es) => QQCopy -> Eff es (Either PlatformFailure ())
recallCopy = send . RecallCopy

muteMember :: (PlatformModeration :> es) => GroupId -> UserId -> Int -> Eff es (Either PlatformFailure ())
muteMember group user seconds = send (MuteMember group user seconds)
