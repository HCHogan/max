-- | Durable draft/evidence facts scoped by a host-minted caller. No VM or tools.
module Max.Skill.Store
  ( AuthoringScope (..),
    saveDraft,
    readDraft,
    inspectDraft,
    recordValidation,
    promoteDraftWithin,
    authoringCallerActive,
  )
where

import Control.Monad (void)
import Data.Aeson
import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Task.Authorization (authorizeCallerWithin)
import Max.DB.Transaction (withReadSnapshot, withTransaction)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Skill.Authoring
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId (..))

data AuthoringScope = AuthoringScope
  { asGroup :: !GroupId,
    asPrincipal :: !PrincipalId,
    asSource :: !CanonicalMessageId,
    asTurn :: !(Maybe AgentTurnId)
  }

authorized :: (WithConnection :> es, IOE :> es) => AuthoringScope -> Eff es Bool
authorized scope = case scope.asTurn of
  Nothing -> pure False
  Just turn -> do
    allowed <- authorizeCallerWithin turn scope.asGroup scope.asPrincipal
    provenance <- query "SELECT EXISTS(SELECT 1 FROM agent_turns WHERE turn_id=? AND trigger_canonical_message_id=?)" (turn, scope.asSource.unCanonicalMessageId)
    pure (allowed && provenance == [Only True])

authoringCallerActive :: (WithConnection :> es, IOE :> es) => AuthoringScope -> Eff es Bool
authoringCallerActive scope = withTransaction (authorized scope)

lockDraft :: (WithConnection :> es, IOE :> es) => AuthoringScope -> Text -> Eff es ()
lockDraft scope name = do
  (_ :: [Only Int]) <- query "SELECT 1::integer FROM (SELECT pg_advisory_xact_lock(hashtextextended('skill-draft:'||?::text||':'||?::text,0))) locked" (groupNumber scope, name)
  pure ()

saveDraft :: (WithConnection :> es, IOE :> es) => AuthoringScope -> DraftContent -> Integer -> Eff es (Either Text DraftVersion)
saveDraft scope draft expected = case validateDraft draft of
  Left err -> pure (Left err)
  Right () -> withTransaction $ do
    allowed <- authorized scope
    if not allowed
      then pure (Left "skill authoring caller is fenced")
      else do
        lockDraft scope draft.dcName
        revisions <- query "SELECT coalesce(max(revision),0) FROM skill_drafts WHERE group_id=? AND name=?" (groupNumber scope, draft.dcName)
        totals <- query "SELECT count(DISTINCT name) FROM skill_drafts WHERE group_id=?" (Only (groupNumber scope))
        case (revisions, totals) of
          ([Only current], [Only count :: Only Int])
            | expected < 0 || current /= expected -> pure (Left "draft revision conflict")
            | current >= 128 || (current == 0 && count >= 32) -> pure (Left "group draft storage limit reached")
            | otherwise -> do
                void $ execute "INSERT INTO skill_drafts(group_id,name,revision,content,created_by) VALUES(?,?,?,?,?)" (groupNumber scope, draft.dcName, current + 1, toJSON draft, scope.asPrincipal.unPrincipalId)
                pure (Right (DraftVersion (current + 1) draft))
          _ -> pure (Left "draft state unavailable")

readDraft :: (WithConnection :> es, IOE :> es) => AuthoringScope -> Text -> Integer -> Eff es (Either Text DraftVersion)
readDraft scope name revision = do
  rows <- query "SELECT content FROM skill_drafts WHERE group_id=? AND name=? AND revision=?" (groupNumber scope, name, revision)
  pure $ case rows of
    [Only value] -> case fromJSON value of
      Success content -> Right (DraftVersion revision content)
      Error _ -> Left "persisted draft is invalid"
    _ -> Left "draft not found in current group"

inspectDraft :: (WithConnection :> es, IOE :> es) => AuthoringScope -> Text -> Maybe Integer -> Eff es (Either Text Value)
inspectDraft scope name version = withReadSnapshot $ do
  selected <- traverse (readDraft scope name) version
  previous <- case version of
    Just revision | revision > 1 -> Just <$> readDraft scope name (revision - 1)
    _ -> pure Nothing
  versions <- query "SELECT revision,recorded_at::text FROM skill_drafts WHERE group_id=? AND name=? ORDER BY revision DESC LIMIT 10" (groupNumber scope, name)
  validations <- query "SELECT validation_id,draft_revision,report FROM skill_validations WHERE group_id=? AND name=? ORDER BY validation_id DESC LIMIT 10" (groupNumber scope, name)
  published <- query "SELECT id,revision,enabled FROM skills WHERE group_id=? AND name=?" (groupNumber scope, name)
  receipts <- query "SELECT skill_revision,draft_revision,validation_id FROM skill_publications WHERE group_id=? AND name=? ORDER BY skill_revision DESC LIMIT 10" (groupNumber scope, name)
  pure $ do
    content <- sequence selected
    Right $
      object
        [ "name" .= name,
          "content" .= content,
          "changes_from_previous" .= case (previous, content) of
            (Just (Right old), Just current) -> Just (object ["from_revision" .= old.dvRevision, "to_revision" .= current.dvRevision, "diff" .= draftDiff old.dvContent current.dvContent])
            _ -> Nothing,
          "recent_drafts" .= [object ["revision" .= rev, "recorded_at" .= time] | (rev :: Integer, time :: Text) <- versions],
          "recent_validations" .= [object ["validation_id" .= identifier, "draft_revision" .= rev, "report" .= report] | (identifier :: Integer, rev :: Integer, report :: Value) <- validations],
          "published" .= [object ["id" .= sid, "revision" .= rev, "enabled" .= enabled] | (sid :: Int64, rev :: Integer, enabled :: Bool) <- published],
          "recent_publications" .= [object ["skill_revision" .= rev, "draft_revision" .= draft, "validation_id" .= proof] | (rev :: Integer, draft :: Integer, proof :: Integer) <- receipts],
          "history_limit" .= (10 :: Int)
        ]

recordValidation :: (WithConnection :> es, IOE :> es) => AuthoringScope -> Text -> Integer -> Value -> ValidationReport -> Eff es (Either Text Value)
recordValidation scope name revision context report = withTransaction $ do
  allowed <- authorized scope
  if not allowed
    then pure (Left "skill authoring caller is fenced")
    else do
      lockDraft scope name
      totals <- query "SELECT count(*) FROM skill_validations WHERE group_id=? AND name=? AND draft_revision=?" (groupNumber scope, name, revision)
      if any (\(Only count :: Only Int) -> count >= 32) totals
        then pure (Left "validation history limit reached; save a new draft")
        else do
          rows <- query "INSERT INTO skill_validations(group_id,name,draft_revision,context,report) VALUES(?,?,?,?,?) RETURNING validation_id" (groupNumber scope, name, revision, context, toJSON report)
          pure $ case rows of
            [Only identifier :: Only Integer] -> Right (object ["validation_id" .= identifier, "draft_revision" .= revision, "report" .= report, "fixture_only" .= True])
            _ -> Left "validation record unavailable"

-- Caller owns the registry gate and standalone commit boundary. No cache update
-- occurs in this function; no validation code executes under this transaction.
promoteDraftWithin :: (WithConnection :> es, IOE :> es) => AuthoringScope -> DraftVersion -> Integer -> Integer -> Value -> Eff es (Either Text Int64)
promoteDraftWithin scope draft validation expected context = do
  allowed <- authorized scope
  if not allowed
    then pure (Left "skill publication caller is fenced")
    else do
      lockDraft scope content.dcName
      proofs <- query "SELECT context,report FROM skill_validations WHERE group_id=? AND name=? AND draft_revision=? AND validation_id=?" (groupNumber scope, content.dcName, draft.dvRevision, validation)
      case proofs of
        [(frozen, raw)] | frozen == context, Success report <- fromJSON raw, validationPassed report -> promote
        _ -> pure (Left "validation missing, failed, or stale; validate this exact draft again")
  where
    content = draft.dvContent
    promote = do
      existing <- query "SELECT id,revision FROM skills WHERE group_id=? AND name=? FOR UPDATE" (groupNumber scope, content.dcName)
      case existing of
        [] | expected == 0 -> do
          prior <- query "SELECT EXISTS(SELECT 1 FROM skill_publications WHERE group_id=? AND name=?)" (groupNumber scope, content.dcName)
          if prior == [Only True]
            then pure (Left "published skill was deleted; choose a new name")
            else do
              rows <- query "INSERT INTO skills(name,group_id,description,body,enabled,created_by,package) VALUES(?,?,?,?,true,?,?) RETURNING id" (content.dcName, groupNumber scope, content.dcDescription, content.dcBody, scope.asPrincipal.unPrincipalId, toJSON content.dcPackage)
              case rows of
                [Only sid] -> receipt sid 1
                _ -> pure (Left "skill insert failed")
        [(sid :: Int64, revision :: Integer)] | revision == expected -> do
          owned <- query "SELECT EXISTS(SELECT 1 FROM skill_publications WHERE skill_id=? AND skill_revision=? AND group_id=? AND name=?)" (sid, revision, groupNumber scope, content.dcName)
          if owned /= [Only True]
            then pure (Left "published head belongs to another writer; use a new name")
            else do
              void $ execute "UPDATE skills SET description=?,body=?,package=?,revision=revision+1,enabled=true,updated_at=now() WHERE id=?" (content.dcDescription, content.dcBody, toJSON content.dcPackage, sid)
              receipt sid (revision + 1)
        _ -> pure (Left "published revision conflict")
    receipt sid revision = do
      void $ execute "INSERT INTO skill_versions(skill_id,revision,snapshot) SELECT id,revision,to_jsonb(skills) FROM skills WHERE id=?" (Only sid)
      void $ execute "INSERT INTO skill_publications(group_id,name,skill_revision,draft_revision,validation_id,skill_id) VALUES(?,?,?,?,?,?)" (groupNumber scope, content.dcName, revision, draft.dvRevision, validation, sid)
      pure (Right sid)

groupNumber :: AuthoringScope -> Int64
groupNumber scope = let GroupId group = scope.asGroup in group
