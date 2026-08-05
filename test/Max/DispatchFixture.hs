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
import Max.Platform.Types
  ( CanonicalMessageId (..),
    NativeUserId (..),
    Platform (PlatformQQ),
    PrincipalId (..),
    PrincipalIdentityId (..),
  )
import OneBot.Segment (Segment (..))
import OneBot.Types (GroupId, MessageId (..), UserId (..))

-- | Test fixture that exercises the real QQ normalizer and then performs the
-- same native-id → principal-identity phase transition as ingestEnvelope.
--
-- Identity and principal ids are derived from the QQ number so a fixture can
-- state one number and have both spaces agree, the way a real 1:1 ledger row
-- does.  Nothing in production may assume that correspondence.
qqDispatch ::
  UserId ->
  GroupId ->
  UserId ->
  MessageId ->
  Maybe Text ->
  [Segment] ->
  DispatchMessage
qqDispatch self group user (MessageId messageId) display segments =
  DispatchMessage
    { selfId = self,
      groupId = group,
      userId = user,
      selfPrincipalId = let UserId raw = self in PrincipalId raw,
      authorPrincipalId = let UserId raw = user in PrincipalId raw,
      canonicalId = CanonicalMessageId messageId,
      body = runIdentity (resolveIngest resolve (qqIngestBody segments)),
      replyTo =
        listToMaybe
          [CanonicalMessageId target | SegReply (MessageId target) <- segments],
      senderDisplayName = display,
      sourcePlatform = PlatformQQ,
      mentionPrincipals =
        Map.fromList
          [ (identity native, principal native)
          | SegAt (UserId nativeId) <- segments,
            let native = NativeUserId (T.pack (show nativeId))
          ]
    }
  where
    resolve native shown = Identity (MentionIdentity (identity native), shown)
    identity (NativeUserId native) = PrincipalIdentityId (read (T.unpack native))
    principal (NativeUserId native) = PrincipalId (read (T.unpack native))
