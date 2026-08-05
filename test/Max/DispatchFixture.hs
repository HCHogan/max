module Max.DispatchFixture
  ( qqDispatch,
  )
where

import Data.Functor.Identity (Identity (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Max.Dispatch (DispatchMessage (..))
import Max.IR (MentionTarget (MentionIdentity), resolveIngest)
import Max.Platform.QQ (qqIngestBody)
import Max.Platform.Types (NativeAccountId (..), NativeUserId (..), Platform (PlatformQQ), PrincipalIdentityId (..))
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId, MessageId (..), UserId (..))

-- | Test fixture that exercises the real QQ normalizer and then performs the
-- same native-id → principal-identity phase transition as ingestEnvelope.
qqDispatch ::
  UserId ->
  GroupId ->
  UserId ->
  MessageId ->
  Maybe Text ->
  [Segment] ->
  DispatchMessage
qqDispatch self group user messageId display segments =
  DispatchMessage
    { selfId = self,
      selfNative = let UserId raw = self in NativeAccountId (T.pack (show raw)),
      groupId = group,
      userId = user,
      messageId,
      body = runIdentity (resolveIngest resolve (qqIngestBody segments)),
      replyToMessageId = listToMaybe [target | SegReply target <- segments],
      senderDisplayName = display,
      sourcePlatform = PlatformQQ,
      mentionNatives =
        Map.fromList
          [ (identity native, native)
          | SegAt (UserId nativeId) <- segments,
            let native = NativeUserId (T.pack (show nativeId))
          ]
    }
  where
    resolve native shown = Identity (MentionIdentity (identity native), shown)
    identity (NativeUserId native) = PrincipalIdentityId (read (T.unpack native))
