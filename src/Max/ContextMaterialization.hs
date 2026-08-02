-- |
-- Durable high/low prompt materialization state.
--
-- Historian publication and prompt materialization are intentionally
-- separate: new projections can be prepared in the background while the
-- prompt keeps one byte-stable compartment prefix.  A CAS publication records
-- the exact active compartment ids/projection versions and their selected
-- tiers, then advances the raw-tail boundary in one known cache bust.
module Max.ContextMaterialization
  ( MaterializedCompartment (..),
    ContextMaterialization (..),
    MaterializationDraft (..),
    loadContextMaterialization,
    publishContextMaterialization,
  )
where

import Control.Exception (throwIO)
import Control.Monad (unless, when)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (In (..), Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query, withTransaction)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.History (MessageCursor (..))
import Max.EpisodeStore (CompartmentId (..))

data MaterializedCompartment = MaterializedCompartment
  { mcCompartmentId :: !CompartmentId,
    mcProjectionVersion :: !Int64,
    mcTier :: !Text
  }
  deriving stock (Show, Eq)

instance ToJSON MaterializedCompartment where
  toJSON item =
    object
      [ "compartment_id" .= item.mcCompartmentId,
        "projection_version" .= item.mcProjectionVersion,
        "tier" .= item.mcTier
      ]

instance FromJSON MaterializedCompartment where
  parseJSON = withObject "materialized_compartment" $ \o ->
    MaterializedCompartment
      <$> o .: "compartment_id"
      <*> o .: "projection_version"
      <*> o .: "tier"

data ContextMaterialization = ContextMaterialization
  { cmConversationId :: !Int64,
    cmRevision :: !Int64,
    cmEndCursor :: !MessageCursor,
    cmPolicyVersion :: !Text,
    cmSourceFingerprint :: !Text,
    cmItems :: ![MaterializedCompartment],
    cmReason :: !Text,
    cmUpdatedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

data MaterializationDraft = MaterializationDraft
  { mdEndCursor :: !MessageCursor,
    mdPolicyVersion :: !Text,
    mdItems :: ![MaterializedCompartment],
    mdReason :: !Text
  }
  deriving stock (Show, Eq)

loadContextMaterialization ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Eff es (Maybe ContextMaterialization)
loadContextMaterialization scope = do
  rows <-
    query
      "SELECT conversation_id, revision, end_ingest_seq, policy_version, source_fingerprint, items::text, reason, updated_at \
      \ FROM context_materializations WHERE conversation_id = ?"
      (Only (conversationStorageId scope))
  case rows :: [(Int64, Int64, Int64, Text, Text, Text, Text, UTCTime)] of
    [] -> pure Nothing
    (conversationId, revision, endCursor, policyVersion, fingerprint, itemsJson, reason, updatedAt) : _ -> do
      items <- decodeItems itemsJson
      let fingerprintDraft =
            MaterializationDraft
              { mdEndCursor = MessageCursor endCursor,
                mdPolicyVersion = policyVersion,
                mdItems = items,
                mdReason = reason
              }
          ids = map (.mcCompartmentId) items
      when (null items) (storeFailure "stored context materialization has no source compartments")
      unless (length ids == length (nub ids)) (storeFailure "stored context materialization has duplicate compartment ids")
      unless (all (\item -> item.mcProjectionVersion > 0 && item.mcTier `elem` allowedTierTexts) items) $
        storeFailure "stored context materialization contains invalid source metadata"
      unless (fingerprint == materializationFingerprint fingerprintDraft) $
        storeFailure "stored context materialization fingerprint mismatch"
      pure $
        Just
          ContextMaterialization
            { cmConversationId = conversationId,
              cmRevision = revision,
              cmEndCursor = MessageCursor endCursor,
              cmPolicyVersion = policyVersion,
              cmSourceFingerprint = fingerprint,
              cmItems = items,
              cmReason = reason,
              cmUpdatedAt = updatedAt
            }

-- | Publish a complete replacement state.  @Nothing@ expects no current row;
-- @Just revision@ is an optimistic CAS.  Active compartment ownership and
-- projection versions are rechecked in the transaction before the boundary
-- can move.
publishContextMaterialization ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  Maybe Int64 ->
  MaterializationDraft ->
  Eff es (Maybe ContextMaterialization)
publishContextMaterialization scope expected draft = withTransaction $ do
  validateDraft scope draft
  let conversationId = conversationStorageId scope
      itemsJson = encodeText draft.mdItems
      fingerprint = materializationFingerprint draft
  revisions <- case expected of
    Nothing ->
      query
        "INSERT INTO context_materializations \
        \ (conversation_id, revision, end_ingest_seq, policy_version, source_fingerprint, items, reason) \
        \ VALUES (?, 1, ?, ?, ?, ?::jsonb, ?) \
        \ ON CONFLICT (conversation_id) DO NOTHING \
        \ RETURNING revision"
        (conversationId, draft.mdEndCursor.ingestSeq, draft.mdPolicyVersion, fingerprint, itemsJson, draft.mdReason)
    Just revision ->
      query
        "UPDATE context_materializations SET \
        \ revision = revision + 1, end_ingest_seq = ?, policy_version = ?, \
        \ source_fingerprint = ?, items = ?::jsonb, reason = ?, updated_at = now() \
        \ WHERE conversation_id = ? AND revision = ? AND end_ingest_seq <= ? \
        \ RETURNING revision"
        (draft.mdEndCursor.ingestSeq, draft.mdPolicyVersion, fingerprint, itemsJson, draft.mdReason, conversationId, revision, draft.mdEndCursor.ingestSeq)
  case revisions :: [Only Int64] of
    [] -> pure Nothing
    Only revision : _ -> do
      inserted <-
        execute
          "INSERT INTO context_materialization_versions \
          \ (conversation_id, revision, end_ingest_seq, policy_version, source_fingerprint, items, reason) \
          \ VALUES (?, ?, ?, ?, ?, ?::jsonb, ?)"
          (conversationId, revision, draft.mdEndCursor.ingestSeq, draft.mdPolicyVersion, fingerprint, itemsJson, draft.mdReason)
      unless (inserted == 1) (storeFailure "failed to append context materialization version")
      loadContextMaterialization scope

validateDraft ::
  (WithConnection :> es, IOE :> es) =>
  ConversationScope ->
  MaterializationDraft ->
  Eff es ()
validateDraft scope draft = do
  when (draft.mdEndCursor.ingestSeq <= 0) (storeFailure "materialization end cursor must be positive")
  when (T.null (T.strip draft.mdPolicyVersion)) (storeFailure "materialization policy version must not be blank")
  unless (draft.mdReason `elem` allowedReasons) (storeFailure "invalid materialization reason")
  when (null draft.mdItems) (storeFailure "materialization must own at least one active compartment")
  let ids = map (.mcCompartmentId) draft.mdItems
  unless (length ids == length (nub ids)) (storeFailure "materialization contains duplicate compartment ids")
  unless (all (\item -> item.mcProjectionVersion > 0 && item.mcTier `elem` allowedTierTexts) draft.mdItems) $
    storeFailure "materialization contains invalid source metadata"
  activeRows <-
    query
      "SELECT id, materialization_version, start_ingest_seq, end_ingest_seq \
      \ FROM conversation_compartments \
      \ WHERE conversation_id = ? AND state = 'active' AND id IN ? \
      \ ORDER BY start_ingest_seq, end_ingest_seq \
      \ FOR SHARE"
      (conversationStorageId scope, In ids)
  let typedActiveRows :: [(CompartmentId, Int64, Int64, Int64)]
      typedActiveRows = activeRows
      expectedRows =
        [ (item.mcCompartmentId, item.mcProjectionVersion)
        | item <- draft.mdItems
        ]
      actualRows = [(compartmentId, version) | (compartmentId, version, _start, _end) <- typedActiveRows]
      maximumEnd = maximum [end | (_compartmentId, _version, _start, end) <- typedActiveRows]
  unless (actualRows == expectedRows) (storeFailure "materialization source compartments are stale, foreign, or inactive")
  unless (maximumEnd == draft.mdEndCursor.ingestSeq) (storeFailure "materialization end cursor does not match its newest compartment")
  gaps <-
    query
      "WITH selected AS ( \
      \  SELECT start_ingest_seq, end_ingest_seq, \
      \         lag(end_ingest_seq) OVER (ORDER BY start_ingest_seq, end_ingest_seq) AS previous_end \
      \  FROM conversation_compartments \
      \  WHERE conversation_id = ? AND state = 'active' AND id IN ? \
      \) \
      \ SELECT EXISTS ( \
      \   SELECT 1 FROM selected AS current \
      \   JOIN messages AS gap_message \
      \     ON gap_message.group_id = ? \
      \    AND gap_message.ingest_seq > current.previous_end \
      \    AND gap_message.ingest_seq < current.start_ingest_seq \
      \   WHERE current.previous_end IS NOT NULL \
      \ )"
      (conversationStorageId scope, In ids, conversationStorageId scope)
  case gaps :: [Only Bool] of
    Only False : _ -> pure ()
    _ -> storeFailure "materialization compartments contain an uncovered raw gap"
  where
    allowedReasons = ["initial_materialization", "high_water", "projection_change", "manual_rebuild"]

allowedTierTexts :: [Text]
allowedTierTexts = ["p1", "p2", "p3", "p4"]

materializationFingerprint :: MaterializationDraft -> Text
materializationFingerprint draft =
  TE.decodeUtf8 . B16.encode . SHA256.hash . LBS.toStrict . encode $
    object
      [ "end_ingest_seq" .= draft.mdEndCursor.ingestSeq,
        "policy_version" .= draft.mdPolicyVersion,
        "items" .= draft.mdItems
      ]

encodeText :: (ToJSON a) => a -> Text
encodeText = TE.decodeUtf8 . LBS.toStrict . encode

decodeItems :: (IOE :> es) => Text -> Eff es [MaterializedCompartment]
decodeItems raw = case eitherDecodeStrict' (TE.encodeUtf8 raw) of
  Left err -> storeFailure ("invalid stored context materialization: " <> err)
  Right items -> pure items

storeFailure :: (IOE :> es) => String -> Eff es a
storeFailure = liftIO . throwIO . userError
