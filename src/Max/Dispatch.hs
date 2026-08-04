-- | Platform-neutral runtime view of a canonical dispatch claim.
--
-- This is deliberately not a transport event. It carries the stored IR,
-- semantic reply relation, and compatibility ids still used by command and
-- context stores. Protocol-specific payloads remain captured on IR nodes and
-- are consumed only by the corresponding ingress worker.
module Max.Dispatch
  ( DispatchMessage (..),
    dispatchText,
    dispatchMentionsSelf,
    stripDispatchVerb,
  )
where

import Data.Char (isSpace)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Max.IR
import Max.IR.Prompt (promptCanonicalText)
import Max.Platform.Types (NativeUserId (..), Platform, PrincipalIdentityId)
import OneBot.Types (GroupId, MessageId, UserId (..))

data DispatchMessage = DispatchMessage
  { selfId :: !UserId,
    groupId :: !GroupId,
    userId :: !UserId,
    messageId :: !MessageId,
    body :: !(Body 'Canonical),
    replyToMessageId :: !(Maybe MessageId),
    senderDisplayName :: !(Maybe Text),
    sourcePlatform :: !Platform,
    mentionNatives :: !(Map PrincipalIdentityId NativeUserId)
  }
  deriving stock (Eq, Show)

dispatchText :: DispatchMessage -> Text
dispatchText message =
  promptCanonicalText message.sourcePlatform message.mentionNatives message.body

dispatchMentionsSelf :: DispatchMessage -> Bool
dispatchMentionsSelf message = any mentionsSelf message.body.nodes
  where
    UserId self = message.selfId
    nativeSelf = T.pack (show self)
    mentionsSelf = \case
      NMention (MentionIdentity identity) _ ->
        Map.lookup identity message.mentionNatives == Just (NativeUserId nativeSelf)
      NMention MentionAll _ -> True
      _ -> False

-- | Remove the first command verb from canonical text while preserving every
-- semantic non-text node and relation. Used by !btw/!feedback when the same
-- durable message is redispatched as conversational input.
stripDispatchVerb :: DispatchMessage -> DispatchMessage
stripDispatchVerb message = message {body = Body (go message.body.nodes)}
  where
    go [] = []
    go (NText text : rest)
      | Just afterBang <- T.stripPrefix "!" (T.stripStart text) =
          NText (T.stripStart (T.dropWhile (not . isSpace) afterBang)) : rest
    go (node : rest) = node : go rest
