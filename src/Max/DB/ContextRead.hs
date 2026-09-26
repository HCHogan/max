-- | Scoped timeline navigation. All continuations recheck authority; episode
-- bounds annotate evidence but do not fence navigation to that episode.
module Max.DB.ContextRead (readContext) where

import Control.Monad (forM)
import Data.Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Int (Int64)
import Data.Maybe (isJust, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.PostgreSQL.Simple (Only (..), Query, (:.) (..))
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Effectful
import Effectful.PostgreSQL (WithConnection, query)
import Max.Context.Read
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.History (historyColumns, notForwardChild, transcriptEligibleExpr)
import Max.DB.History.Media (withMediaHandles)
import Max.Episode.Types (parseEpisodeHandle)
import Max.History.Types (HistoryItem (..))

data Row = Row
  { position :: !Int64,
    history :: !HistoryItem,
    occurred :: !UTCTime,
    episode :: !(Maybe Text),
    hasForward :: !Bool,
    recordKind :: !Text,
    promptEligible :: !Bool
  }

instance FromRow Row where
  fromRow = Row <$> field <*> fromRow <*> field <*> field <*> field <*> field <*> field

data EpisodeInfo = EpisodeInfo !Text !Int64 !Int64 !Text !Bool

readContext :: (WithConnection :> es, IOE :> es) => ConversationScope -> Int -> ReadRequest -> Eff es (Either Text Value)
readContext scope tokens request = case request.rrCursor of
  Just raw -> case decodeReadCursor gid raw of
    Left err -> pure (Left err)
    Right cursor -> continue cursor
  Nothing -> case request.rrRef of
    Just (MemoryRef mid) -> memory mid
    Just (MessageRef mid) -> do
      found <- message mid
      case found of
        Nothing -> pure (Left "message not found or not visible in this range/conversation")
        Just anchor -> do
          let countBefore = min request.rrBefore ((pageSize - 1) `div` 2 + if request.rrAfter == 0 then pageSize else 0)
              countAfter = min request.rrAfter (pageSize - 1 - min (pageSize - 1) countBefore)
              cursor = initial Timeline Nothing False anchor.position
          older <- rows cursor {rcBackward = True} (min (pageSize - 1) countBefore)
          newer <- rows cursor countAfter
          page cursor (Just (messageRef mid)) (reverse older <> [anchor] <> newer)
    Just (EpisodeRef handle) -> do
      info <- episodeInfo handle
      case info of
        Nothing -> pure (Left "episode not found or not visible in this conversation")
        Just (EpisodeInfo ref start _ _ _) -> continue (initial Timeline (Just ref) False (start - 1))
    Just (ForwardRef mid) -> continue (initial (Forward mid) Nothing False 0)
    Nothing -> continue (initial Timeline Nothing (not (isJust request.rrFrom || isJust request.rrUntil)) (if isJust request.rrFrom || isJust request.rrUntil then 0 else maxBound))
  where
    gid = conversationStorageId scope
    pageSize = min request.rrLimit (max 1 (min 100 (tokens `div` 256)))
    initial lane ep backward at = ReadCursor 1 gid lane request.rrFrom request.rrUntil ep backward at pageSize

    continue cursor = case cursor.rcLane of
      Observation {} -> pure (Left "node observation requires its owning live task")
      Body mid offset fingerprint -> do
        found <- messageUnfiltered mid
        case found of
          Nothing -> pure (Left "message not found or not visible in this conversation")
          Just row -> do
            enriched <- enrich row
            if textFingerprint enriched.history.renderedText /= fingerprint
              then pure (Left "message changed since the previous page; read its ref again")
              else do
                item <- render cursor (max 1 (tokens - 160)) offset enriched
                pure (Right (object ["items" .= [item], "prev" .= Null, "next" .= Null]))
      _ -> do
        let bounded = cursor {rcLimit = min cursor.rcLimit (max 1 (tokens `div` 256))}
        selected <- rows bounded bounded.rcLimit
        page bounded Nothing (if bounded.rcBackward then reverse selected else selected)

    page cursor anchor selected = do
      info <- case cursor.rcEpisode >>= parseEpisodeHandle of
        Nothing -> pure Nothing
        Just handle -> episodeInfo handle
      -- Check even on continuation: a stale/deleted episode is not a license
      -- to invent its evidence boundaries.
      case (cursor.rcEpisode, info) of
        (Just _, Nothing) -> pure (Left "episode no longer visible")
        _ -> do
          let perItem = max 1 (tokens `div` max 1 (length selected) - 160)
          items <- forM selected $ \row -> do
            enriched <- enrich row
            value <- render cursor perItem 0 enriched
            pure $ case (value, info) of
              (Object fields, Just (EpisodeInfo _ start end _ _)) -> Object (fields <> KM.fromList ["in_episode" .= (row.position >= start && row.position <= end)])
              _ -> value
          prev <- neighbor cursor True (listToMaybe selected)
          next <- neighbor cursor False (listToMaybe (reverse selected))
          pure . Right $
            object
              [ "items" .= items,
                "prev" .= prev,
                "next" .= next,
                "anchor" .= anchor,
                "range" .= object ["from" .= cursor.rcFrom, "until" .= cursor.rcUntil, "time_field" .= ("received_at" :: Text)],
                "episode" .= fmap episodeValue info,
                "order" .= (case cursor.rcLane of Forward _ -> "forward_position"; _ -> "ingest" :: Text)
              ]

    neighbor _ _ Nothing = pure Null
    neighbor cursor backward (Just row) = do
      let next = cursor {rcBackward = backward, rcAt = row.position}
      available <- rows next 1
      pure (if null available then Null else readLink next)

    enrich row = do
      enriched <- withMediaHandles [row.history]
      pure $ case enriched of h : _ -> row {history = h}; [] -> row

    render cursor budget offset row =
      pure $ case renderReadMessage cursor budget offset row.history row.occurred row.episode row.hasForward of
        Object fields -> Object (KM.insert "message_kind" (String row.recordKind) (KM.insert "prompt_eligible" (Bool row.promptEligible) fields))
        value -> value

    message mid = do
      found <- messageUnfiltered mid
      pure $ found >>= \row -> if inRange row.history.receivedAt then Just row else Nothing
    inRange at = maybe True (<= at) request.rrFrom && maybe True (at <) request.rrUntil
    messageUnfiltered mid = listToMaybe <$> query (selectRow <> " WHERE group_id=? AND canonical_message_id=?") (gid, mid)

    rows _ count | count <= 0 = pure []
    rows cursor count = case cursor.rcLane of
      Timeline ->
        query
          ( selectRow
              <> " WHERE group_id=? AND "
              <> notForwardChild "messages"
              <> " AND ingest_seq "
              <> comparison cursor
              <> " ?"
              <> timeFilter
              <> " ORDER BY ingest_seq "
              <> direction cursor
              <> " LIMIT ?"
          )
          ((gid, cursor.rcAt) :. times cursor :. Only count)
      Forward parent ->
        query
          ( "WITH children AS (SELECT child.*, row_number() OVER (ORDER BY r.relation_position, r.relation_id) AS child_position "
              <> "FROM messages child JOIN message_relations r ON r.canonical_message_id=child.canonical_message_id AND r.relation_kind='contained_in' "
              <> "JOIN messages parent ON parent.canonical_message_id=r.target_canonical_message_id "
              <> "WHERE child.group_id=? AND parent.group_id=? AND parent.canonical_message_id=?) "
              <> selectForward
              <> " WHERE child_position "
              <> comparison cursor
              <> " ?"
              <> timeFilter
              <> " ORDER BY child_position "
              <> direction cursor
              <> " LIMIT ?"
          )
          ((gid, gid, parent, cursor.rcAt) :. times cursor :. Only count)
      Body {} -> pure []
      Observation {} -> pure []

    episodeInfo handle = do
      found <-
        query
          "SELECT expand_handle::text, start_ingest_seq, end_ingest_seq, state, source_hash=conversation_source_hash(conversation_id,start_ingest_seq,end_ingest_seq) FROM conversation_compartments WHERE conversation_id=? AND expand_handle=?"
          (gid, handle)
      pure $ case found of (ref, start, end, state, matches) : _ -> Just (EpisodeInfo ref start end state matches); [] -> Nothing
    episodeValue (EpisodeInfo ref start end state matches) =
      object
        ["ref" .= ("episode:" <> ref), "start_cursor" .= T.pack (show start), "end_cursor" .= T.pack (show end), "state" .= state, "source_hash_matches" .= matches]

    memory mid = do
      found <-
        query
          "SELECT jsonb_build_object('kind','memory','ref','memory:'||m.id::text, \
          \ 'text',m.content,'complete',true,'version',m.version::text,'lifecycle',m.lifecycle, \
          \ 'subject',m.scope,'subject_id',m.scope_id::text,'updated_at',m.updated_at, \
          \ 'evidence',COALESCE((SELECT jsonb_agg(jsonb_build_object( \
          \   'kind',e.evidence_kind,'note',e.note, \
          \   'message',CASE WHEN source.canonical_message_id IS NOT NULL THEN jsonb_build_object('ref','message:'||source.canonical_message_id::text) END, \
          \   'episode',CASE WHEN ep.expand_handle IS NOT NULL THEN jsonb_build_object('ref','episode:'||ep.expand_handle::text) END, \
          \   'start_cursor',e.source_start_ingest_seq::text,'end_cursor',e.source_end_ingest_seq::text) ORDER BY e.id) \
          \ FROM memory_evidence e \
          \ LEFT JOIN messages source ON source.canonical_message_id=COALESCE(e.source_canonical_message_id, \
          \   (SELECT canonical_message_id FROM messages origin WHERE origin.group_id=e.source_conversation_id \
          \      AND origin.ingest_seq BETWEEN e.source_start_ingest_seq AND e.source_end_ingest_seq ORDER BY origin.ingest_seq LIMIT 1)) \
          \   AND source.group_id=? \
          \ LEFT JOIN conversation_compartments ep ON ep.id=e.source_episode_id AND ep.conversation_id=? \
          \ WHERE e.memory_id=m.id AND e.memory_version=m.version AND e.source_conversation_id=?),'[]'::jsonb)) \
          \ FROM memories m WHERE m.id=? \
          \   AND ((m.scope='group' AND m.scope_id=?) OR (m.scope='user' AND m.source_group_id=?)) \
          \   AND (?::timestamptz IS NULL OR m.updated_at>=?) AND (?::timestamptz IS NULL OR m.updated_at<?)"
          ((gid, gid, gid, mid, gid, gid) :. (request.rrFrom, request.rrFrom, request.rrUntil, request.rrUntil))
      pure $ case found :: [Only Value] of
        Only value : _ -> Right (object ["items" .= [value], "prev" .= Null, "next" .= Null])
        [] -> Left "memory not found or not visible in this conversation"

selectRow, selectForward, rowExtras, timeFilter :: Query
selectRow = "SELECT ingest_seq, " <> historyColumns <> rowExtras <> " FROM messages"
selectForward = "SELECT child_position, " <> historyColumns <> rowExtras <> " FROM children AS messages"
rowExtras = ", occurred_at, (SELECT expand_handle::text FROM conversation_compartments ep WHERE ep.conversation_id=messages.group_id AND ep.state='active' AND messages.ingest_seq BETWEEN ep.start_ingest_seq AND ep.end_ingest_seq LIMIT 1), EXISTS(SELECT 1 FROM message_relations rel WHERE rel.target_canonical_message_id=messages.canonical_message_id AND rel.relation_kind='contained_in'), kind, " <> transcriptEligibleExpr
timeFilter = " AND (?::timestamptz IS NULL OR received_at>=?) AND (?::timestamptz IS NULL OR received_at<?)"

times :: ReadCursor -> (Maybe UTCTime, Maybe UTCTime, Maybe UTCTime, Maybe UTCTime)
times cursor = (cursor.rcFrom, cursor.rcFrom, cursor.rcUntil, cursor.rcUntil)

comparison, direction :: ReadCursor -> Query
comparison cursor = if cursor.rcBackward then "<" else ">"
direction cursor = if cursor.rcBackward then "DESC" else "ASC"
