-- | Hook definitions and ingest decisions share the conversation commit lock.
-- Raw message reads here are administrative evidence, never agent context.
module Max.DB.Hook (setHook, queryHooks, evaluateSnapshot) where

import Control.Applicative ((<|>))
import Control.Monad (forM, void)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..))
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Effectful
import Effectful.PostgreSQL (WithConnection, execute, query)
import Max.DB.Codec (Jsonb (..), jsonbField)
import Max.DB.ConversationLock (lockConversation)
import Max.DB.Transaction (InTransaction, requireTransaction)
import Max.Hook.Runtime (runHook, validateSource)
import Max.Hook.Types

newtype JsonRow = JsonRow Value

instance FromRow JsonRow where
  fromRow = JsonRow <$> jsonbField

newtype Stored = Stored HookDefinition

instance FromRow Stored where
  fromRow = Stored <$> (HookDefinition <$> field <*> field <*> field <*> jsonbField <*> field)

definition :: (WithConnection :> es, IOE :> es) => Int64 -> Text -> Maybe Int -> Eff es (Maybe HookDefinition)
definition group n rev = do
  rows <-
    query
      "SELECT v.name,v.revision,v.source,v.config,v.enabled FROM message_hook_versions v JOIN conversations c USING(conversation_id) JOIN message_hooks h USING(conversation_id,name) WHERE c.legacy_group_id=? AND v.name=? AND v.revision=COALESCE(?,h.revision)"
      (group, n, rev)
  pure (listToMaybe [d | Stored d <- rows])

setHook :: (InTransaction :> es, WithConnection :> es, IOE :> es) => Int64 -> Int64 -> HookPatch -> Eff es (Either Text Value)
setHook group actor patch = do
  requireTransaction
  locked <- lockConversation group
  if not locked
    then pure (Left "conversation_not_found")
    else do
      previous <- definition group patch.hpName Nothing
      case applyHookPatch patch previous of
        Left err -> pure (Left err)
        Right next -> do
          counts <- query "SELECT count(*) FROM message_hooks h JOIN conversations c USING(conversation_id) WHERE c.legacy_group_id=?" (Only group)
          if isNothing previous && any (\(Only count) -> count >= fromIntegral maxHooks) (counts :: [Only Int64])
            then pure (Left "hook limit reached (8 per conversation); reuse an existing definition name")
            else do
              valid <- if maybe False ((== next.source) . (.source)) previous then pure (Right ()) else validateSource next.source
              case valid of
                Left err -> pure (Left err)
                Right () -> do
                  void $ execute "INSERT INTO message_hooks(conversation_id,name,revision) SELECT conversation_id,?,? FROM conversations WHERE legacy_group_id=? ON CONFLICT(conversation_id,name) DO UPDATE SET revision=EXCLUDED.revision" (next.name, next.revision, group)
                  rows <-
                    query
                      "INSERT INTO message_hook_versions(conversation_id,name,revision,event,source,config,enabled,actor_principal_id,effective_after_ingest_seq) SELECT c.conversation_id,?,?,'message.inbound',?,?,?,?,COALESCE((SELECT max(ingest_seq) FROM messages WHERE conversation_id=c.conversation_id),0) FROM conversations c WHERE legacy_group_id=? RETURNING effective_after_ingest_seq"
                      (next.name, next.revision, next.source, Jsonb next.config, next.enabled, actor, group)
                  let boundary = case rows of [Only n] -> n :: Int64; _ -> error "hook version insertion cardinality"
                      changed = [key | (key, yes) <- [("source", maybe True ((/= next.source) . (.source)) previous), ("config", maybe True ((/= next.config) . (.config)) previous), ("enabled", maybe True ((/= next.enabled) . (.enabled)) previous)], yes] :: [Text]
                  pure . Right $ object ["name" .= next.name, "revision" .= next.revision, "enabled" .= next.enabled, "changed" .= changed, "effective_after_ingest_seq" .= boundary, "applies_to" .= ("newly ingested messages only" :: Text)]

queryHooks :: (WithConnection :> es, IOE :> es) => Int64 -> HookQuery -> Eff es (Either Text Value)
queryHooks group = \case
  HookList -> do
    rows <-
      query
        "SELECT jsonb_build_object('name',v.name,'event',v.event,'revision',v.revision,'enabled',v.enabled,'updated_at',v.created_at,'last_error',(SELECT jsonb_build_object('message_id',r.canonical_message_id,'revision',r.revision,'reason',r.reason,'at',r.created_at) FROM message_hook_runs r WHERE r.conversation_id=v.conversation_id AND r.name=v.name AND r.outcome='error' ORDER BY r.run_id DESC LIMIT 1)) FROM message_hooks h JOIN message_hook_versions v USING(conversation_id,name,revision) JOIN conversations c USING(conversation_id) WHERE c.legacy_group_id=? ORDER BY v.name"
        (Only group)
    pure (Right (object ["hooks" .= [v | JsonRow v <- rows :: [JsonRow]]]))
  HookGet n rev -> do
    rows <-
      query
        "SELECT jsonb_build_object('name',v.name,'event',v.event,'revision',v.revision,'source',v.source,'config',v.config,'enabled',v.enabled,'updated_at',v.created_at,'actor_principal',v.actor_principal_id,'effective_after_ingest_seq',v.effective_after_ingest_seq) FROM message_hook_versions v JOIN message_hooks h USING(conversation_id,name) JOIN conversations c USING(conversation_id) WHERE c.legacy_group_id=? AND v.name=? AND v.revision=COALESCE(?,h.revision)"
        (group, n, rev)
    pure $ case rows of [JsonRow v] -> Right v; _ -> Left "hook_or_revision_not_found"
  HookRuns n outcomeFilter mid before count -> do
    rows <-
      query
        "SELECT jsonb_build_object('run_id',r.run_id,'name',r.name,'revision',r.revision,'message_id',r.canonical_message_id,'outcome',r.outcome,'reason',r.reason,'elapsed_ms',r.elapsed_ms,'effective_action',CASE WHEN r.outcome='pass' THEN 'pass' ELSE 'ignore' END,'message_ignored',NOT EXISTS(SELECT 1 FROM agent_messages a WHERE a.canonical_message_id=r.canonical_message_id),'projection_status',p.status,'at',r.created_at) FROM message_hook_runs r JOIN conversations c USING(conversation_id) JOIN message_projections p USING(canonical_message_id) WHERE c.legacy_group_id=? AND (?::text IS NULL OR r.name=?) AND (?::text IS NULL OR r.outcome=?) AND (?::bigint IS NULL OR r.canonical_message_id=?) AND (?::bigint IS NULL OR r.run_id<?) ORDER BY r.run_id DESC LIMIT ?"
        (group, n, n, outcomeFilter, outcomeFilter, mid, mid, before, before, count + 1)
    let values = [v | JsonRow v <- rows :: [JsonRow]]
        page = take count values
        cursor = if length values > count then case reverse page of Object o : _ -> KM.lookup "run_id" o; _ -> Nothing else Nothing
    pure (Right (object ["runs" .= page, "next_before" .= cursor]))
  HookTest n rev code cfg input -> do
    previous <- maybe (pure Nothing) (\name -> definition group name rev) n
    event <- case input of
      Right sample -> pure (Just sample)
      Left mid -> loadEvent group mid
    if isJust n && isNothing previous
      then pure (Left "hook_or_revision_not_found")
      else case (code <|> fmap (.source) previous, event) of
        (Nothing, _) -> pure (Left "source_required")
        (_, Nothing) -> pure (Left "message_not_found_in_current_conversation")
        (Just source, Just sample) -> do
          let candidate = HookDefinition (fromMaybe "test" n) (maybe 0 (.revision) previous) source (fromMaybe (maybe (object []) (.config) previous) cfg) True
          case validateDefinition candidate of
            Left err -> pure (Left err)
            Right () -> do
              result <- runHook candidate sample
              pure . Right $ object ["simulation" .= True, "base_revision" .= fmap (.revision) previous, "enabled" .= fmap (.enabled) previous, "candidate_overrides" .= ([key | (key, yes) <- [("source", isJust code), ("config", isJust cfg)], yes] :: [Text]), "result" .= resultValue result]
  HookProjection mid -> do
    rows <-
      query
        "SELECT jsonb_build_object('message_id',p.canonical_message_id,'status',p.status,'work_pending',p.work_pending,'context_visible',p.context_visible,'allow_activation',p.allow_activation,'currently_visible',EXISTS(SELECT 1 FROM agent_messages a WHERE a.canonical_message_id=p.canonical_message_id),'dispatch_status',d.status,'last_error',p.last_error,'dispatch_error',d.last_error,'evaluated_at',p.evaluated_at,'hooks',COALESCE((SELECT jsonb_agg(jsonb_build_object('name',s.name,'revision',s.revision) ORDER BY s.name) FROM message_hook_snapshots s WHERE s.canonical_message_id=p.canonical_message_id),'[]'::jsonb)) FROM message_projections p JOIN conversations c USING(conversation_id) LEFT JOIN message_projection_dispatches d USING(canonical_message_id) WHERE c.legacy_group_id=? AND p.canonical_message_id=?"
        (group, mid)
    pure $ case rows of [JsonRow v] -> Right v; _ -> Left "message_not_found_in_current_conversation"

-- The same projection feeds real execution and historical simulation. No raw
-- platform payload is exposed as identity or authority.
loadEvent :: (WithConnection :> es, IOE :> es) => Int64 -> Int64 -> Eff es (Maybe Value)
loadEvent group mid = do
  rows <-
    query
      "SELECT jsonb_build_object('type','message.inbound','message_id',canonical_message_id,'sender_principal',author_principal_id,'text',rendered_text,'body',canonical_content,'platform',source_platform,'received_at',received_at,'occurred_at',occurred_at,'ingest_class',ingest_class,'reply_to',reply_to_canonical_message_id) FROM messages WHERE group_id=? AND canonical_message_id=? AND message_origin='inbound' AND event_kind='message'"
      (group, mid)
  pure (listToMaybe [v | JsonRow v <- rows :: [JsonRow]])

-- | Run only the immutable versions selected when this message was stored.
-- The projection worker owns a separate, committed-after-ingest transaction.
evaluateSnapshot :: (InTransaction :> es, WithConnection :> es, IOE :> es) => Int64 -> Int64 -> Eff es (Bool, Bool)
evaluateSnapshot group mid = do
  requireTransaction
  definitions <- query "SELECT v.name,v.revision,v.source,v.config,v.enabled FROM message_hook_snapshots s JOIN message_hook_versions v USING(conversation_id,name,revision) WHERE s.canonical_message_id=? ORDER BY v.name" (Only mid)
  case definitions of
    [] -> pure (False, False)
    _ ->
      loadEvent group mid >>= \case
        Nothing -> error "hook snapshot source message disappeared"
        Just event -> do
          results <- forM definitions $ \(Stored d) -> do
            r <- runHook d event
            void $ execute "INSERT INTO message_hook_runs(conversation_id,name,revision,canonical_message_id,outcome,reason,elapsed_ms) SELECT conversation_id,?,?,?,?,?,? FROM conversations WHERE legacy_group_id=?" (d.name, d.revision, mid, r.outcome, r.reason, r.elapsedMs, group)
            pure r
          pure (any hookIgnored results, any ((== "error") . (.outcome)) results)
