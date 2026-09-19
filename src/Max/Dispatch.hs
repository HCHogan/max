-- | Canonical content and principal identities used by commands and Agent.
-- Platform wire formats remain in their adapters.
module Max.Dispatch
  ( DispatchMessage (..),
    dispatchText,
    dispatchTextWithoutSelf,
    dispatchMentionsSelf,
    dispatchMentionsSelfDirectly,
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
import Max.Platform.Types (CanonicalMessageId, Platform, PrincipalId, PrincipalIdentityId)
import OneBot.Types (GroupId, UserId (..))

data DispatchMessage = DispatchMessage
  { selfId :: !UserId,
    groupId :: !GroupId,
    userId :: !UserId,
    -- | The bot as a person. Comparing this against a mention's resolved
    -- principal is what "was I addressed?" means on every platform.
    selfPrincipalId :: !PrincipalId,
    -- | The sender as a person — the handle the model reads them by.
    authorPrincipalId :: !PrincipalId,
    canonicalId :: !CanonicalMessageId,
    body :: !(Body 'Canonical),
    replyTo :: !(Maybe CanonicalMessageId),
    senderDisplayName :: !(Maybe Text),
    -- | Which transport carried this.  Command and delivery plumbing needs
    -- it (permissions differ off-QQ, and a foreign source has no reaction to
    -- ack with); nothing rendered to the model reads it, which is the point
    -- of ADR 004.
    sourcePlatform :: !Platform,
    -- | Identity → principal for every mention in 'body'. One always-defined
    -- join, captured before rendering so no projection performs lookups.
    mentionPrincipals :: !(Map PrincipalIdentityId PrincipalId)
  }
  deriving stock (Eq, Show)

dispatchText :: DispatchMessage -> Text
dispatchText message = promptCanonicalText message.mentionPrincipals message.body

-- | Remove self-mentions structurally before rendering command/prompt text.
-- Native mention spellings differ across platforms; rendered-text replacement
-- would not consistently identify the bot.
dispatchTextWithoutSelf :: DispatchMessage -> Text
dispatchTextWithoutSelf message =
  promptCanonicalText
    message.mentionPrincipals
    (Body (trimEdges (mergeText (filter (not . selfMention message) message.body.nodes))))

-- | Did this message address the bot?  A mention of everyone counts; a
-- mention of the bot counts through whichever account carried it, because
-- the comparison is between people.
dispatchMentionsSelf :: DispatchMessage -> Bool
dispatchMentionsSelf message = any addressesSelf message.body.nodes
  where
    addressesSelf node = selfMention message node || mentionAll node
    mentionAll = \case
      NMention MentionAll _ -> True
      _ -> False

-- | A resolved mention of Max specifically, excluding room-wide mentions.
dispatchMentionsSelfDirectly :: DispatchMessage -> Bool
dispatchMentionsSelfDirectly message = any (selfMention message) message.body.nodes

selfMention :: DispatchMessage -> Node 'Canonical -> Bool
selfMention message = \case
  NMention (MentionIdentity identity) _ ->
    Map.lookup identity message.mentionPrincipals == Just message.selfPrincipalId
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
