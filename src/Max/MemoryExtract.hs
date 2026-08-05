-- |
-- Provenance-aware semantic-memory maintenance.  Episode capture and memory
-- proposal generation now live in 'Max.Historian'; this module retains the
-- nightly shrink pass and its legacy operation parser only.
module Max.MemoryExtract
  ( dreamWorker,

    -- * Exposed for tests
    ExtractOp (..),
    parseOps,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Data.Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_, traverse_)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time
  ( LocalTime (..),
    TimeOfDay (..),
    TimeZone,
    addDays,
    diffUTCTime,
    getCurrentTime,
    localDay,
    localTimeOfDay,
    localTimeToUTC,
    utc,
    utcToLocalTime,
  )
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (conversationScopeFor)
import Max.Effects.LLM (ChatCtx (..), ChatMessage (..), ChatResponse (..), LLM, chat)
import Max.MaintenanceLease
  ( MaintenanceDomain (MemoryDreamMaintenance),
    withMaintenanceLease,
  )
import Max.MemoryStore
  ( ExpectedVersion (..),
    MemoryActor (..),
    MemoryActorKind (..),
    MemoryEvidence (..),
    MemoryId (..),
    MemoryItem (..),
    MemoryMaintenanceCandidate (..),
    MemoryMaintenanceEntry (..),
    MemoryMutationResult (..),
    MemoryScope (..),
    MemoryUpdate (..),
    MemoryVersion (..),
    archiveMemoryWithEvidence,
    listMemoryMaintenanceCandidates,
    listMemoryMaintenanceEntries,
    memoryNamespace,
    parseScope,
    scopeText,
    supersedeMemoryWithEvidence,
    updateMemory,
  )
import Max.Time (fmtDate)
import Max.Tools.Memory (checkContent)
import Max.Util (catchSync)
import OneBot.Types (GroupId (..))

-- | One operation the extractor model may emit.
data ExtractOp
  = OpAdd !Text !(Maybe Int64) !Text -- scope, user_id (scope=user), content
  | OpUpdate !MemoryId !MemoryVersion !Text !Text
  | OpArchive !MemoryId !MemoryVersion !Text
  | OpSupersede !MemoryId !MemoryVersion !MemoryId !Text
  deriving stock (Show, Eq)

instance FromJSON ExtractOp where
  parseJSON = withObject "op" $ \o -> do
    action <- o .: "action"
    case action :: Text of
      "add" -> OpAdd <$> o .: "scope" <*> o .:? "user_id" <*> o .: "content"
      "update" ->
        OpUpdate
          <$> o .: "id"
          <*> o .: "version"
          <*> o .: "content"
          <*> (fromMaybe "legacy maintenance update" <$> o .:? "reason")
      "delete" -> parseArchive "legacy maintenance delete" o
      "archive" -> parseArchive "maintenance archive" o
      "supersede" ->
        OpSupersede
          <$> o .: "id"
          <*> o .: "version"
          <*> o .: "replacement_id"
          <*> (fromMaybe "maintenance supersede" <$> o .:? "reason")
      other -> fail ("unknown action: " <> T.unpack other)
    where
      parseArchive fallback o =
        OpArchive
          <$> o .: "id"
          <*> o .: "version"
          <*> (fromMaybe fallback <$> o .:? "reason")

-- | Parse the model's output into ops: strip code fences, find the
-- first @[@ .. last @]@, decode.
parseOps :: Text -> Either String [ExtractOp]
parseOps raw =
  let t = T.strip (stripFences (T.strip raw))
      sliced = case (T.findIndex (== '[') t, T.length t - 1) of
        (Just i, _) -> T.drop i (T.dropWhileEnd (/= ']') t)
        _ -> t
   in eitherDecode (LBS.fromStrict (TE.encodeUtf8 sliced))
  where
    stripFences s
      | "```" `T.isPrefixOf` s =
          T.intercalate "\n"
            . takeWhile (not . ("```" `T.isPrefixOf`))
            . drop 1
            $ T.lines s
      | otherwise = s

mutationResultText :: MemoryMutationResult -> Text
mutationResultText MemoryMutationApplied {} = "applied"
mutationResultText MemoryMutationRejected = "rejected"

--------------------------------------------------------------------------------
-- Shrink passes: compaction (cap pressure) and dreaming (nightly).

-- | A scope only gets dreamed once it holds this many entries.
dreamMinEntries :: Int
dreamMinEntries = 15

-- | Local hour the nightly pass runs at.
dreamHourLocal :: Int
dreamHourLocal = 4

-- | Nightly consolidation (the auto-dream pattern): once a day, at
-- 'dreamHourLocal' local time, every recently-touched scope holding
-- 'dreamMinEntries'+ entries gets a gentle shrink pass — merge
-- overlapping entries, drop superseded ones, rewrite relative time to
-- absolute dates.  The 49-hour change window covers a night missed to
-- downtime without re-dreaming dormant scopes forever; a repeat pass
-- over an already-tidy scope is a cheap "[]".
dreamWorker ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- process-unique lease owner
  Text -> -- extractor profile
  TimeZone ->
  Eff es ()
dreamWorker owner profile tz = localDomain "memory-dream" . forever $ do
  liftIO (sleepUntilHour tz dreamHourLocal)
  leasedNight `catchSync` \e ->
    logAttention "dream: night crashed" $ object ["error" .= T.pack (show e)]
  where
    leasedNight =
      withMaintenanceLease MemoryDreamMaintenance owner dreamLeaseSeconds (const night) >>= \case
        Nothing -> logInfo "dream: another worker owns maintenance lease" (object [])
        Just () -> pure ()

    night = do
      now <- liftIO getCurrentTime
      candidates <- listMemoryMaintenanceCandidates dreamMinEntries
      for_ candidates $ \candidate ->
        let scopeRaw = candidate.maintenanceScope
            sid = candidate.maintenanceSubjectId
            gid = candidate.maintenanceConversationId
            n = candidate.maintenanceCount
         in for_ (parseScope scopeRaw) $ \scope -> do
              logInfo "dream: scope" $
                object ["scope" .= scopeRaw, "scope_id" .= sid, "entries" .= n]
              shrinkScope
                "memory-dream"
                dreamerSystem
                ["今天是 " <> fmtDate tz now, ""]
                profile
                scope
                sid
                gid
                `catchSync` \e ->
                  logAttention "dream: scope crashed" $
                    object ["scope_id" .= sid, "error" .= T.pack (show e)]

dreamLeaseSeconds :: Int
dreamLeaseSeconds = 6 * 60 * 60

-- | Sleep until the next occurrence of @hour:00@ local time.
sleepUntilHour :: TimeZone -> Int -> IO ()
sleepUntilHour tz hour = do
  now <- getCurrentTime
  let lt = utcToLocalTime tz now
      at = TimeOfDay hour 0 0
      nextLt
        | localTimeOfDay lt < at = LocalTime (localDay lt) at
        | otherwise = LocalTime (addDays 1 (localDay lt)) at
      next = localTimeToUTC tz nextLt
      micros = max 1_000_000 (ceiling (diffUTCTime next now * 1_000_000)) :: Integer
  threadDelay (fromIntegral micros)

-- | One shrink-only LLM pass over a full scope.  Reuses the
-- extraction op format/parser; @add@ ops are ignored — a shrink pass
-- must only ever shrink.
shrinkScope ::
  (LLM :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  Text -> -- ChatCtx label / log prefix
  Text -> -- system prompt
  [Text] -> -- extra input header lines
  Text -> -- profile
  MemoryScope ->
  Int64 ->
  Int64 ->
  Eff es ()
shrinkScope label sys header profile scope sid gid = do
  entries <- listMemoryMaintenanceEntries namespace
  let memLine entry =
        T.pack (show entry.mmeMemory.memId.unMemoryId)
          <> "@v"
          <> T.pack (show entry.mmeMemory.memVersion.unMemoryVersion)
          <> " ("
          <> entry.mmeMemory.memLifecycle
          <> maybe "" ("/" <>) entry.mmeMemory.memCategory
          <> ", updated="
          <> fmtDate utc entry.mmeMemory.memUpdatedAt
          <> ", evidence="
          <> renderMaintenanceEvidence entry
          <> "): "
          <> entry.mmeMemory.memContent
      input =
        T.unlines $
          header
            <> ( ("[memories — scope=" <> scopeText scope <> " id=" <> T.pack (show sid) <> "]")
                   : map memLine entries
               )
            <> ["", "输出操作 JSON 数组："]
  chat (ChatCtx label (Just gid) Nothing Nothing Nothing) profile [MsgSystem sys, MsgUser input] [] >>= \case
    Left err -> logAttention (label <> ": chat failed") $ object ["error" .= err]
    Right (ToolCallsResp {}) ->
      logAttention (label <> ": unexpected tool calls") $ object []
    Right (ContentResp raw) -> case parseOps raw of
      Left err ->
        logAttention (label <> ": bad ops json") $
          object ["error" .= err, "raw" .= T.take 400 raw]
      Right ops -> do
        let shrinkOnly = [op | op <- ops, notAdd op]
            notAdd OpAdd {} = False
            notAdd _ = True
        traverse_ apply (take 12 shrinkOnly)
        logInfo (label <> ": scope done") $
          object
            [ "scope" .= scopeText scope,
              "scope_id" .= sid,
              "ops" .= length shrinkOnly
            ]
  where
    apply = \case
      OpAdd {} -> pure ()
      OpUpdate mid version content reason -> case (,) <$> checkContent content <*> checkReason reason of
        Left err -> logAttention (label <> ": bad content") $ object ["error" .= err]
        Right (c, why) -> do
          result <-
            updateMemory
              (actor why)
              namespace
              mid
              (ExpectedVersion version)
              (MemoryUpdate c (MaintenanceEvidence conversation why))
          logInfo (label <> ": updated") $
            object ["id" .= mid, "result" .= mutationResultText result, "reason" .= why, "content" .= c]
      OpArchive mid version reason -> case checkReason reason of
        Left err -> logAttention (label <> ": bad archive reason") $ object ["error" .= err]
        Right why -> do
          result <-
            archiveMemoryWithEvidence
              (actor why)
              namespace
              mid
              (ExpectedVersion version)
              (MaintenanceEvidence conversation why)
          logInfo (label <> ": archived") $
            object ["id" .= mid, "result" .= mutationResultText result, "reason" .= why]
      OpSupersede mid version replacement reason -> case checkReason reason of
        Left err -> logAttention (label <> ": bad supersede reason") $ object ["error" .= err]
        Right why -> do
          result <-
            supersedeMemoryWithEvidence
              (actor why)
              namespace
              mid
              (ExpectedVersion version)
              replacement
              (MaintenanceEvidence conversation why)
          logInfo (label <> ": superseded") $
            object
              [ "id" .= mid,
                "replacement_id" .= replacement,
                "result" .= mutationResultText result,
                "reason" .= why
              ]

    conversation = conversationScopeFor (GroupId gid)
    actor why =
      MemoryActor
        ActorDreamer
        Nothing
        (Just why)
    namespace =
      memoryNamespace
        conversation
        scope
        sid

checkReason :: Text -> Either Text Text
checkReason raw
  | T.null reason = Left "reason 不能为空"
  | T.length reason > 300 = Left "reason 太长（最多 300 字）"
  | otherwise = Right reason
  where
    reason = T.strip raw

renderMaintenanceEvidence :: MemoryMaintenanceEntry -> Text
renderMaintenanceEvidence entry =
  fromMaybe "missing" entry.mmeEvidenceKind
    <> maybe "" (("@conversation#" <>) . tshow) entry.mmeSourceConversationId
    <> maybe "" (("/principal#" <>) . tshow) entry.mmeSourcePrincipalId
    <> maybe "" (("/message#" <>) . tshow) entry.mmeSourceMessageId
    <> rangePart
    <> maybe "" (("/episode#" <>) . tshow) entry.mmeSourceEpisodeId
    <> maybe "" ((" note=" <>) . T.take 120) entry.mmeEvidenceNote
    <> maybe "" ((" at=" <>) . fmtDate utc) entry.mmeEvidenceAt
  where
    rangePart = case (entry.mmeSourceStartIngestSeq, entry.mmeSourceEndIngestSeq) of
      (Just start, Just end) -> "/range#" <> tshow start <> "-" <> tshow end
      _ -> ""
    tshow = T.pack . show

dreamerSystem :: Text
dreamerSystem =
  T.unlines
    [ "你在夜间整理一个 QQ bot 的长期记忆库。每条带稳定 id、version、lifecycle、",
      "最后更新日期和当前版本的来源 evidence；今天的日期在输入头部。证据不足就不动。",
      "  - 同主题/重叠条目 → 先 update 保留项，再把其余项 supersede 到保留项。",
      "  - 新事实有更晚、更明确的 message/range/episode evidence，取代旧事实 →",
      "    supersede 旧项到新项；不能仅凭措辞更像真的来判断。",
      "  - 明确有期限且已经过期、又没有替代项的事实 → archive。",
      "  - 条目内容里的相对时间（\"最近\"\"上周\"\"昨天\"）→ 按该条的更新日期换算，",
      "    update 成绝对日期。",
      "lifecycle=permanent 的条目绝不能修改、归档或 supersede。没什么可整理就输出 []。",
      "最多 12 个操作；按 update 在前、依赖它的 supersede 在后的顺序。content 用第三人称",
      "陈述句，≤300 字且自包含。每个操作必须给出基于输入 evidence/date 的具体 reason。",
      "只输出 JSON 数组，只允许：",
      "  {\"action\":\"update\",\"id\":5,\"version\":2,\"content\":\"...\",\"reason\":\"...\"}",
      "  {\"action\":\"supersede\",\"id\":6,\"version\":1,\"replacement_id\":5,\"reason\":\"...\"}",
      "  {\"action\":\"archive\",\"id\":7,\"version\":3,\"reason\":\"...\"}"
    ]
