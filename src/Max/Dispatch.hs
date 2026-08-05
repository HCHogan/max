-- | Platform-neutral runtime view of a canonical dispatch claim.
--
-- This is deliberately not a transport event. It carries the stored IR,
-- semantic reply relation, and compatibility ids still used by command and
-- context stores. Protocol-specific payloads remain captured on IR nodes and
-- are consumed only by the corresponding ingress worker.
module Max.Dispatch
  ( DispatchMessage (..),
    dispatchText,
    dispatchTextWithoutSelf,
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
import Max.Platform.Types (NativeAccountId (..), NativeUserId (..), Platform, PrincipalIdentityId)
import OneBot.Types (GroupId, MessageId, UserId (..))

data DispatchMessage = DispatchMessage
  { selfId :: !UserId,
    -- | The bot's id on the origin platform.  'selfId' is a compatibility
    -- bigint that only coincides with it on QQ.
    selfNative :: !NativeAccountId,
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

-- | The same text with the bot's own mentions removed — what the command
-- parser and the current-message line want, since @\@max help@ is a request
-- for help, not for "@max help".
--
-- Structural by necessity: deleting the /rendered/ token only ever worked on
-- QQ, where the mention renders as the bot's compatibility id.  A Matrix
-- mention renders as @\@max:server@ and an iMessage one as a handle, so the
-- node is the only thing every platform agrees on.
dispatchTextWithoutSelf :: DispatchMessage -> Text
dispatchTextWithoutSelf message =
  promptCanonicalText
    message.sourcePlatform
    message.mentionNatives
    (Body (trimEdges (mergeText (filter (not . selfMention message) message.body.nodes))))

-- | Did this message address the bot?  A mention of everyone counts; a
-- mention of the bot by identity counts however that identity spells itself
-- on the origin platform.
dispatchMentionsSelf :: DispatchMessage -> Bool
dispatchMentionsSelf message = any addressesSelf message.body.nodes
  where
    addressesSelf node = selfMention message node || mentionAll node
    mentionAll = \case
      NMention MentionAll _ -> True
      _ -> False

selfMention :: DispatchMessage -> Node 'Canonical -> Bool
selfMention message = \case
  NMention (MentionIdentity identity) _ ->
    Map.lookup identity message.mentionNatives == Just native
  _ -> False
  where
    NativeAccountId account = message.selfNative
    native = NativeUserId account

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
