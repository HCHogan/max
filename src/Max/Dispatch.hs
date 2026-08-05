-- | Platform-neutral runtime view of a canonical dispatch claim.
--
-- This is deliberately not a transport event. It carries the stored IR, the
-- semantic reply relation, and the canonical identities everything
-- model-facing is named by. The compatibility ids that remain
-- ('selfId', 'groupId', 'userId') are the session/command/admin plumbing ADR
-- 003 deliberately left alone; nothing rendered to a model reads them.
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

-- | The same text with the bot's own mentions removed — what the command
-- parser and the current-message line want, since @\@max help@ is a request
-- for help, not for "@max help".
--
-- Structural by necessity: deleting the /rendered/ token only ever worked on
-- QQ, where the mention used to render as the bot's compatibility id.  A
-- Matrix mention rendered as @\@max:server@ and an iMessage one as a handle,
-- so the node is the only thing every platform agrees on.
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
