-- | Caption-only assembly around the shared canonical reply resolver.
module Max.Reply.Caption (captionBody) where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Conversation.Roster (ConversationRoster (..), RosterIdentity (..))
import Max.Effects.Blob (Blob)
import Max.IR
import Max.Platform.Store (conversationRoster)
import Max.Platform.Types (AdvertisedCaps (..), CanonicalMessageId)
import Max.Reply (chunkSource, planReply)
import Max.Reply.Resolve
import OneBot.Types (GroupId (..))

-- | Captions share the canonical resolver, including scoped reply and mention
-- lookup. Layout folds to one message; the attachment supplies its own media.
captionBody ::
  (Blob :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  AdvertisedCaps -> GroupId -> Maybe Text -> Eff es (Maybe CanonicalMessageId, Body 'Canonical)
captionBody _ _ Nothing = pure (Nothing, Body [])
captionBody caps gid@(GroupId group) (Just caption) = do
  roster <- conversationRoster group
  let target =
        ResolveContext
          gid
          [(name, identity.riPrincipalId) | identity <- roster.crIdentities, Just name <- [identity.riDisplayName]]
          Nothing
          False
          caps.canReply
          caps.canMention
          caps.canFace
          False
  (_, reply, body) <-
    resolveModelText
      target
      Set.empty
      (T.intercalate "\n" (map chunkSource (planReply (cleanModelText caption))))
  pure (reply, Body (if null body.nodes then [] else body.nodes <> [NText "\n"]))
