-- | Pure projections for ADR 005's digest continuity tier.  Durable facts
-- are loaded by 'Max.DB.TurnContinuity'; this module only decides how those
-- facts are rendered and how catalog drift is fingerprinted.
module Max.Turn.Continuity
  ( TurnDigest (..),
    JournalDigest (..),
    AmbientMessage (..),
    SandboxState (..),
    SandboxDrift (..),
    ContinuationDigest (..),
    currentPromptMajor,
    toolCatalogFingerprint,
    renderRecentTurn,
    renderContinuationDigest,
    renderReplayDelta,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString.Base16 qualified as B16
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (TimeZone, UTCTime)
import Max.Time (fmtDateHM)
import Max.Tool.Types
  ( SchemaVersion (..),
    ToolDefinition (..),
    ToolRef (..),
  )
import Max.Turn.Types (TurnOrdinal, turnHandleText)

data TurnDigest = TurnDigest
  { tdTurnOrdinal :: !TurnOrdinal,
    tdStatus :: !Text,
    tdProfile :: !(Maybe Text),
    tdStartedAt :: !UTCTime,
    tdFinishedAt :: !(Maybe UTCTime),
    tdToolCount :: !Int64,
    tdSandboxHandles :: ![Text],
    tdLastOutputId :: !(Maybe Int64),
    tdLastOutputFirstLine :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

data JournalDigest = JournalDigest
  { jdOrdinal :: !Int64,
    jdKind :: !Text,
    jdState :: !Text,
    jdToolRef :: !(Maybe Text),
    jdInputSummary :: !(Maybe Text),
    jdResultSummary :: !(Maybe Text),
    jdFailureSummary :: !(Maybe Text),
    jdObservedManifest :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

data AmbientMessage = AmbientMessage
  { amCanonicalId :: !Int64,
    amAuthor :: !Text,
    amPreview :: !Text
  }
  deriving stock (Show, Eq)

data SandboxState = SandboxState
  { ssHandle :: !Text,
    ssStatus :: !Text
  }
  deriving stock (Show, Eq)

data SandboxDrift = SandboxDrift
  { sdHandle :: !Text,
    sdByTurn :: !TurnOrdinal,
    sdAt :: !UTCTime,
    sdManifest :: !Text
  }
  deriving stock (Show, Eq)

data ContinuationDigest = ContinuationDigest
  { cdTurn :: !TurnDigest,
    cdJournal :: ![JournalDigest],
    cdOutputs :: ![(Int, Int64, Text)], -- chunk, canonical id, preview
    cdElapsedSeconds :: !Integer,
    cdInterveningCount :: !Int64,
    cdInterveningMessages :: ![AmbientMessage],
    cdSandboxStates :: ![SandboxState],
    cdSandboxDrift :: ![SandboxDrift],
    cdPromptChanged :: !(Maybe Bool),
    cdCatalogChanged :: !(Maybe Bool)
  }
  deriving stock (Show, Eq)

-- Increment when the semantic contract of the host prompt changes.  E1 adds
-- the t# namespace and continuation disclosure rules, so it is prompt major 2.
currentPromptMajor :: Int
currentPromptMajor = 2

-- | Stable over inventory ordering and intentionally excludes credentials or
-- runner closures.  Schema changes are represented by schema-version bumps.
toolCatalogFingerprint :: [ToolDefinition] -> Text
toolCatalogFingerprint =
  TE.decodeUtf8
    . B16.encode
    . SHA256.hash
    . TE.encodeUtf8
    . T.intercalate "\n"
    . map renderDefinition
    . sortOn (\definition -> definition.tdRef.unToolRef)
  where
    renderDefinition definition =
      T.intercalate
        "|"
        [ definition.tdRef.unToolRef,
          tshow definition.tdSchemaVersion.unSchemaVersion,
          renderList definition.tdEffects,
          tshow definition.tdParallelism,
          tshow definition.tdRetryClass,
          renderList definition.tdAuthorities
        ]
    renderList :: (Foldable f, Show a, Ord a) => f a -> Text
    renderList = T.intercalate "," . map tshow . sortOn id . foldr (:) []

renderRecentTurn :: TimeZone -> TurnDigest -> Text
renderRecentTurn tz digest =
  T.unwords
    [ turnHandleText digest.tdTurnOrdinal,
      fmtDateHM tz digest.tdStartedAt,
      statusGlyph digest.tdStatus <> output,
      "· " <> tshow digest.tdToolCount <> " tools"
    ]
    <> sandboxPart
    <> outputPart
  where
    output = maybe "" (\line -> "「" <> oneLine line <> "」") digest.tdLastOutputFirstLine
    sandboxPart = case digest.tdSandboxHandles of
      [] -> ""
      handles -> " · sandbox " <> T.intercalate "," handles
    outputPart = maybe "" (\messageId -> " ↦ #" <> tshow messageId) digest.tdLastOutputId

renderContinuationDigest :: TimeZone -> ContinuationDigest -> Text
renderContinuationDigest tz digest =
  T.intercalate
    "\n"
    ( [ "[continuation — host digest; no archived provider-wire replay]",
        "你正在续接 " <> turnHandleText turn.tdTurnOrdinal <> "（" <> turn.tdStatus <> profile <> "）。",
        "之前的可见输出：" <> outputs,
        "之前的规范化执行记录："
      ]
        <> journalLines
        <> ["环境变化（由 ledger/journal 确定生成）："]
        <> ambientDeltaLines tz digest
    )
  where
    turn = digest.cdTurn
    profile = maybe "" ("，profile=" <>) turn.tdProfile
    outputs = case digest.cdOutputs of
      [] -> "（无）"
      rows -> T.intercalate "；" ["#" <> tshow mid <> "「" <> oneLine body <> "」" | (_, mid, body) <- rows]
    journalLines = case digest.cdJournal of
      [] -> ["- （无 journal 行）"]
      rows -> map renderJournal rows

-- | The replay tier's companion note.
--
-- One projection, two windows: the digest tier states the whole record
-- because nothing else carries it, while the replay tier has just shown that
-- record verbatim and needs only what changed since — restating the journal
-- underneath the wire items would show the same work twice in two registers,
-- which is exactly what ledger dedup exists to prevent.
renderReplayDelta :: TimeZone -> ContinuationDigest -> Text
renderReplayDelta tz digest =
  T.intercalate
    "\n"
    ( [ "[continuation — 以上是你之前完成 "
          <> turnHandleText turn.tdTurnOrdinal
          <> " 的工作过程（原样保留，含你当时的思考）。]",
        "环境变化（由 ledger/journal 确定生成）："
      ]
        <> ambientDeltaLines tz digest
    )
  where
    turn = digest.cdTurn

-- | Drift since the continued turn finished: elapsed time and intervening
-- chatter from the ledger, world-state drift from the sandbox observed
-- manifests, and environment versions from the journal's own columns.  Shared
-- by both tiers so drift is described identically however the work above it
-- was rendered.
ambientDeltaLines :: TimeZone -> ContinuationDigest -> [Text]
ambientDeltaLines tz digest = ambientLines
  where
    ambientLines =
      [ "- 距它结束已过 " <> renderDuration digest.cdElapsedSeconds <> "。",
        "- 期间新增 " <> tshow digest.cdInterveningCount <> " 条消息" <> messageSamples <> "。",
        "- 沙盒状态：" <> sandboxStates <> "。",
        "- 沙盒观测变化：" <> sandboxDrift <> "。",
        "- prompt major " <> changed digest.cdPromptChanged <> "；工具目录 " <> changed digest.cdCatalogChanged <> "。"
      ]
    messageSamples = case digest.cdInterveningMessages of
      [] -> ""
      rows -> "，其中 " <> T.intercalate "；" ["#" <> tshow row.amCanonicalId <> " " <> row.amAuthor <> "「" <> oneLine row.amPreview <> "」" | row <- rows]
    sandboxStates = case digest.cdSandboxStates of
      [] -> "未引用持久沙盒"
      rows -> T.intercalate "；" [row.ssHandle <> "=" <> row.ssStatus | row <- rows]
    sandboxDrift = case digest.cdSandboxDrift of
      [] -> "无记录"
      rows -> T.intercalate "；" [row.sdHandle <> " 被 " <> turnHandleText row.sdByTurn <> " 于 " <> fmtDateHM tz row.sdAt <> " 观测为 " <> oneLine row.sdManifest | row <- rows]

renderJournal :: JournalDigest -> Text
renderJournal row =
  "- r"
    <> tshow row.jdOrdinal
    <> " "
    <> row.jdKind
    <> maybe "" (" " <>) row.jdToolRef
    <> " ["
    <> row.jdState
    <> "]"
    <> field " args=" row.jdInputSummary
    <> field " result=" row.jdResultSummary
    <> field " failure=" row.jdFailureSummary
    <> field " observed=" row.jdObservedManifest
  where
    field label = maybe "" (\value -> label <> "「" <> oneLine value <> "」")

statusGlyph :: Text -> Text
statusGlyph = \case
  "succeeded" -> "✓"
  "silence" -> "◇ silence"
  "aborted" -> "✗ aborted"
  "failed" -> "✗ failed"
  "crashed" -> "✗ crashed"
  other -> "· " <> other

changed :: Maybe Bool -> Text
changed = \case
  Just True -> "已变化"
  Just False -> "无变化"
  Nothing -> "版本未知"

renderDuration :: Integer -> Text
renderDuration rawSeconds
  | seconds < 60 = tshow seconds <> "s"
  | seconds < 3600 = tshow (seconds `div` 60) <> "m"
  | seconds < 86400 = tshow (seconds `div` 3600) <> "h" <> tshow ((seconds `mod` 3600) `div` 60) <> "m"
  | otherwise = tshow (seconds `div` 86400) <> "d" <> tshow ((seconds `mod` 86400) `div` 3600) <> "h"
  where
    seconds = max 0 rawSeconds

oneLine :: Text -> Text
oneLine = T.take 240 . T.unwords . T.words

tshow :: (Show a) => a -> Text
tshow = T.pack . show
