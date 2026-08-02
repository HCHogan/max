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
import Max.MemoryStore
  ( ExpectedVersion (..),
    MemoryActor (..),
    MemoryActorKind (..),
    MemoryEvidence (..),
    MemoryId (..),
    MemoryItem (..),
    MemoryMaintenanceCandidate (..),
    MemoryMutationResult (..),
    MemoryScope (..),
    MemoryUpdate (..),
    MemoryVersion (..),
    archiveMemory,
    listMemories,
    listMemoryMaintenanceCandidates,
    memoryNamespace,
    parseScope,
    scopeText,
    updateMemory,
  )
import Max.Time (fmtDate)
import Max.Tools.Memory (checkContent)
import Max.Util (catchSync)
import OneBot.Types (GroupId (..))

-- | One operation the extractor model may emit.
data ExtractOp
  = OpAdd !Text !(Maybe Int64) !Text -- scope, user_id (scope=user), content
  | OpUpdate !MemoryId !MemoryVersion !Text
  | OpDelete !MemoryId !MemoryVersion
  deriving stock (Show, Eq)

instance FromJSON ExtractOp where
  parseJSON = withObject "op" $ \o -> do
    action <- o .: "action"
    case action :: Text of
      "add" -> OpAdd <$> o .: "scope" <*> o .:? "user_id" <*> o .: "content"
      "update" -> OpUpdate <$> o .: "id" <*> o .: "version" <*> o .: "content"
      "delete" -> OpDelete <$> o .: "id" <*> o .: "version"
      other -> fail ("unknown action: " <> T.unpack other)

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
  Text -> -- extractor profile
  TimeZone ->
  Eff es ()
dreamWorker profile tz = localDomain "memx-dream" . forever $ do
  liftIO (sleepUntilHour tz dreamHourLocal)
  night `catchSync` \e ->
    logAttention "dream: night crashed" $ object ["error" .= T.pack (show e)]
  where
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
                "memx-dream"
                dreamerSystem
                ["今天是 " <> fmtDate tz now, ""]
                profile
                scope
                sid
                gid
                `catchSync` \e ->
                  logAttention "dream: scope crashed" $
                    object ["scope_id" .= sid, "error" .= T.pack (show e)]

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
  mems <- listMemories namespace
  let memLine m =
        T.pack (show m.memId.unMemoryId)
          <> "@v"
          <> T.pack (show m.memVersion.unMemoryVersion)
          <> " ("
          <> fmtDate utc m.memUpdatedAt
          <> "): "
          <> m.memContent
      input =
        T.unlines $
          header
            <> ( ("[memories — scope=" <> scopeText scope <> " id=" <> T.pack (show sid) <> "]")
                   : map memLine mems
               )
            <> ["", "输出操作 JSON 数组："]
  chat (ChatCtx label (Just gid) Nothing) profile [MsgSystem sys, MsgUser input] [] >>= \case
    Left err -> logAttention (label <> ": chat failed") $ object ["error" .= err]
    Right (ToolCallsResp _ _ _) ->
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
      OpUpdate mid version content -> case checkContent content of
        Left err -> logAttention (label <> ": bad content") $ object ["error" .= err]
        Right c -> do
          result <-
            updateMemory
              actor
              namespace
              mid
              (ExpectedVersion version)
              (MemoryUpdate c (MaintenanceEvidence conversation label))
          logInfo (label <> ": merged") $ object ["id" .= mid, "result" .= mutationResultText result, "content" .= c]
      OpDelete mid version -> do
        result <- archiveMemory actor namespace mid (ExpectedVersion version)
        logInfo (label <> ": archived") $ object ["id" .= mid, "result" .= mutationResultText result]

    conversation = conversationScopeFor (GroupId gid)
    actor =
      MemoryActor
        (if label == "memx-dream" then ActorDreamer else ActorExtractor)
        Nothing
        (Just label)
    namespace =
      memoryNamespace
        conversation
        scope
        sid

dreamerSystem :: Text
dreamerSystem =
  T.unlines
    [ "你在夜间整理一个 QQ bot 的长期记忆库（关于某个群或某个人；每条带 id 和",
      "最后更新日期，今天的日期在输入头部）。做四类整理，能不动就不动：",
      "  - 同主题/重叠的条目 → 合并：对其中一条 update 成合并后的表述，其余 delete。",
      "  - 明显过时、或被更新的条目取代的 → delete。",
      "  - 条目内容里的相对时间（\"最近\"\"上周\"\"昨天\"）→ 按该条的更新日期换算，",
      "    update 成绝对日期。",
      "  - 互相矛盾的条目 → 保留较新的事实，update 完善它，delete 旧的。",
      "没什么可整理就输出 []。最多 12 个操作。合并后的 content 用第三人称陈述句，",
      "≤300 字，自包含。",
      "只输出 JSON 数组，只允许 update / delete：",
      "  {\"action\":\"update\",\"id\":5,\"version\":2,\"content\":\"...\"}",
      "  {\"action\":\"delete\",\"id\":5,\"version\":2}"
    ]
