{-# LANGUAGE DataKinds #-}

-- | Canonical body plus event relations form the rendered history projection.
-- Both verification and offline regeneration must use this same reader.
module Max.DB.Projection (ProjectionRow (..), projectionRows, expectedProjection) where

import Data.Aeson (Result (..), Value, fromJSON)
import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Connection, query_)
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Effectful (runEff)
import Effectful.PostgreSQL.Connection (runWithConnection)
import Max.IR (Body, Phase (Canonical), mentionIdentities)
import Max.IR.Prompt (promptCanonicalText, systemEventText)
import Max.Platform.Store (mentionPrincipalsFor)
import Max.Platform.Types (EventKind (..))

data ProjectionRow = ProjectionRow
  { canonicalMessageId :: !Int64,
    canonicalContent :: !Value,
    renderedText :: !Text,
    messageKind :: !Text,
    eventKind :: !Text,
    relationTarget :: !(Maybe Int64),
    reactionKey :: !(Maybe Text),
    reactionAdded :: !Bool
  }

instance FromRow ProjectionRow where
  fromRow = ProjectionRow <$> field <*> field <*> field <*> field <*> field <*> field <*> field <*> field

projectionRows :: Connection -> IO [ProjectionRow]
projectionRows connection = query_ connection
  "SELECT m.canonical_message_id,m.canonical_content,m.rendered_text,m.kind,m.event_kind, \
  \ relation.target_canonical_message_id,relation.reaction_key, \
  \ NOT EXISTS (SELECT 1 FROM message_relations r WHERE r.canonical_message_id=m.canonical_message_id AND r.relation_kind='reaction' AND NOT r.reaction_added) \
  \FROM messages m LEFT JOIN LATERAL (SELECT target_canonical_message_id,reaction_key FROM message_relations r \
  \ WHERE r.canonical_message_id=m.canonical_message_id AND r.relation_kind IN ('replace','redacts','reaction') \
  \ ORDER BY relation_position NULLS LAST,relation_id LIMIT 1) relation ON true ORDER BY m.canonical_message_id"

expectedProjection :: Connection -> ProjectionRow -> IO (Either String Text)
expectedProjection connection row = case fromJSON row.canonicalContent of
  Error err -> pure (Left ("canonical message " <> show row.canonicalMessageId <> " is not decodable v2 IR: " <> err))
  -- Debug records predate public system-event projection, and internal
  -- reaction receipts still use their canonical body (often empty). Event kind
  -- alone does not authorize replacing that body with a public event token.
  Success (body :: Body 'Canonical) | row.messageKind /= "system" -> bodyProjection body
  Success body -> case row.eventKind of
    "message" -> do
      bodyProjection body
    "edit" -> event EventEdit
    "redaction" -> event EventRedaction
    "reaction" -> event EventReaction
    "membership" -> event EventMembership
    _ -> pure (Left ("unknown event kind on canonical message " <> show row.canonicalMessageId))
  where
    bodyProjection body = do
      principals <- runEff . runWithConnection connection $ mentionPrincipalsFor (mentionIdentities body)
      pure (Right (promptCanonicalText principals body))
    event kind = pure (Right (systemEventText kind row.relationTarget row.reactionKey row.reactionAdded))
