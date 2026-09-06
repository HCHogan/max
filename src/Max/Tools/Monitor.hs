-- | Agent-facing ADR 006 monitor vocabulary.  Reminder tools remain stable
-- sugar for TimeCron+canned; these tools arm intent-carrying elaborated turns
-- and expose the unified m# namespace.
module Max.Tools.Monitor
  ( monitorToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone, UTCTime, addUTCTime)
import Effectful
import Effectful.Reader.Static (Reader, ask)
import Max.Effects.MonitorControl (MonitorControl, armMonitor)
import Max.Effects.MonitorControl qualified as Control
import Max.Effects.MonitorQuery (MonitorQuery, listMonitors, readMonitorHistory)
import Max.Effects.Tools (Tool (..))
import Max.IR (MediaKind (..))
import Max.Monitor.Control
import Max.Monitor.Policy (parseOverlapPolicy)
import Max.Monitor.Schedule (nextCronFire)
import Max.Monitor.Types
import Max.Monitor.View (ArmedMonitor (..))
import Max.Platform.Types (PrincipalId (..))
import Max.Task.Types (parseProfile)
import Max.Time (fmtDateHM)
import Max.Time.Parse (parseTimeArg)
import Max.Tools.Schema (boolParam, boundedIntegerParam, enumParam, integerParam, noArguments, stringParam, toolObject)
import System.Cron.Parser (parseCronSchedule)

monitorToolsFor ::
  (MonitorQuery :> es, MonitorControl :> es, Reader UTCTime :> es) =>
  TimeZone ->
  [Tool es]
monitorToolsFor tz =
  [armMonitorTool tz, listMonitorsTool tz, cancelMonitorTool, configureMonitorTool, monitorHistoryTool]

data ArmArgs = ArmArgs
  { aaGoal :: !Text,
    aaTrigger :: !Text,
    aaInMinutes :: !(Maybe Int),
    aaAt :: !(Maybe Text),
    aaCron :: !(Maybe Text),
    aaSenderPrincipal :: !(Maybe Int64),
    aaTextContains :: !(Maybe Text),
    aaMediaKind :: !(Maybe Text),
    aaMentionSelf :: !Bool,
    aaCooldownSeconds :: !Int,
    aaTtlDays :: !Int,
    aaMaxFires :: !Int64
  }

armMonitorTool ::
  (MonitorControl :> es, Reader UTCTime :> es) =>
  TimeZone ->
  Tool es
armMonitorTool tz =
  Tool
    { toolName = "arm_monitor",
      toolDescription =
        "武装一个在条件满足后创建后台任务的 monitor。默认 single-flight + 一个 coalesced pending；结果有变化才通知。trigger=time 用 in_minutes/at/cron；trigger=ledger 至少提供一个条件。只观察武装后的 live 入站，历史导入不会触发。用 configure_monitor 修改目标/重叠策略，用 monitor_history 查看版本、排队和失败历史。",
      toolSchema =
        toolObject
          [ ("goal", stringParam "触发后要重新思考并完成的目标，不是到点原样发送的文本。"),
            ("trigger", enumParam ["time", "ledger"] "触发器类型。"),
            ("in_minutes", integerParam "time：几分钟后一次性触发。"),
            ("at", stringParam "time：显示时区的 YYYY-MM-DD HH:MM。"),
            ("cron", stringParam "time：5 段 cron，循环触发。"),
            ("sender_principal", integerParam "ledger：可选的 [@#principal] 人物 id。"),
            ("text_contains", stringParam "ledger：Unicode 不区分大小写的包含匹配。"),
            ("media_kind", enumParam ["image", "sticker", "video", "audio", "file"] "ledger：媒体类型。"),
            ("mention_self", boolParam "ledger：消息是否 @ 了 Max（默认 false）。"),
            ("cooldown_seconds", boundedIntegerParam 0 86400 60),
            ("ttl_days", boundedIntegerParam 1 1825 150),
            ("max_fires", boundedIntegerParam 1 100 100)
          ]
          ["goal", "trigger"],
      toolRun = \raw -> case parseEither (withObject "args" parseArm) raw of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right args
          | T.null (T.strip args.aaGoal) -> pure (Left "goal 不能为空")
          | args.aaCooldownSeconds < 0 || args.aaCooldownSeconds > 86400 -> pure (Left "cooldown_seconds 必须在 0..86400")
          | args.aaTtlDays < 1 || args.aaTtlDays > 1825 -> pure (Left "ttl_days 必须在 1..1825")
          | args.aaMaxFires < 1 || args.aaMaxFires > 100 -> pure (Left "max_fires 必须在 1..100")
          | otherwise -> do
              now <- ask @UTCTime
              case args.aaTrigger of
                "time" -> case resolveTime tz args now of
                  Left err -> pure (Left err)
                  Right (cron, fireAt) -> do
                    armed <- armMonitor (Control.TimeMonitor (T.strip args.aaGoal) cron fireAt)
                    pure (armResult tz fireAt cron armed)
                "ledger" -> case ledgerSpec args of
                  Left err -> pure (Left err)
                  Right spec -> do
                    let expires = addUTCTime (fromIntegral (args.aaTtlDays * 86400)) now
                    armed <- armMonitor (Control.LedgerMonitor (T.strip args.aaGoal) spec args.aaCooldownSeconds expires args.aaMaxFires)
                    pure $
                      case armed of
                        Left err -> Left (armErrorText err)
                        Right ref ->
                          Right $
                            object
                              [ "ok" .= True,
                                "handle" .= monitorHandleText ref.mrMonitorOrdinal,
                                "trigger" .= ("ledger" :: Text),
                                "expires" .= fmtDateHM tz expires,
                                "max_fires" .= args.aaMaxFires,
                                "cooldown_seconds" .= args.aaCooldownSeconds
                              ]
                _ -> pure (Left "trigger 必须是 time 或 ledger")
    }
  where
    parseArm o =
      ArmArgs
        <$> o .: "goal"
        <*> o .: "trigger"
        <*> o .:? "in_minutes"
        <*> o .:? "at"
        <*> o .:? "cron"
        <*> o .:? "sender_principal"
        <*> o .:? "text_contains"
        <*> o .:? "media_kind"
        <*> (fromMaybe False <$> o .:? "mention_self")
        <*> (fromMaybe 60 <$> o .:? "cooldown_seconds")
        <*> (fromMaybe 150 <$> o .:? "ttl_days")
        <*> (fromMaybe 100 <$> o .:? "max_fires")

resolveTime :: TimeZone -> ArmArgs -> UTCTime -> Either Text (Maybe Text, UTCTime)
resolveTime tz args now = case (args.aaInMinutes, args.aaAt, args.aaCron) of
  (Just minutes, Nothing, Nothing)
    | minutes <= 0 -> Left "in_minutes 必须是正整数"
    | minutes > 2635200 -> Left "in_minutes 太大了（上限约五年）"
    | otherwise -> Right (Nothing, addUTCTime (fromIntegral (minutes * 60)) now)
  (Nothing, Just absolute, Nothing) -> do
    fireAt <- parseTimeArg tz absolute
    if fireAt <= now then Left "指定的时间已经过去了" else Right (Nothing, fireAt)
  (Nothing, Nothing, Just expression) -> case parseCronSchedule (T.strip expression) of
    Left err -> Left ("cron 表达式无效：" <> T.pack err)
    Right schedule -> case nextCronFire tz schedule now of
      Nothing -> Left "这个 cron 表达式算不出下一次触发时间"
      Just fireAt -> Right (Just (T.strip expression), fireAt)
  (Nothing, Nothing, Nothing) -> Left "time trigger 必须指定 in_minutes / at / cron 之一"
  _ -> Left "in_minutes / at / cron 只能给一个"

ledgerSpec :: ArmArgs -> Either Text LedgerMatchSpec
ledgerSpec args = do
  parsedMedia <- traverse parseMediaKind args.aaMediaKind
  parseLedgerMatchSpec $
    ledgerMatchSpecValue
      LedgerMatchSpec
        { lmsSenderPrincipal = PrincipalId <$> args.aaSenderPrincipal,
          lmsTextContains = T.strip <$> args.aaTextContains,
          lmsMediaKind = parsedMedia,
          lmsMentionSelf = args.aaMentionSelf
        }
  where
    parseMediaKind = \case
      "image" -> Right MImage
      "sticker" -> Right MSticker
      "video" -> Right MVideo
      "audio" -> Right MAudio
      "file" -> Right MFile
      _ -> Left "media_kind 必须是 image/sticker/video/audio/file"

armResult :: TimeZone -> UTCTime -> Maybe Text -> Either MonitorArmError MonitorRef -> Either Text Value
armResult tz fireAt cron = \case
  Left err -> Left (armErrorText err)
  Right ref ->
    Right $
      object
        [ "ok" .= True,
          "handle" .= monitorHandleText ref.mrMonitorOrdinal,
          "trigger" .= ("time" :: Text),
          "next_fire" .= fmtDateHM tz fireAt,
          "recurring" .= isJust cron,
          "cron" .= cron
        ]

listMonitorsTool :: (MonitorQuery :> es) => TimeZone -> Tool es
listMonitorsTool tz =
  Tool
    { toolName = "list_monitors",
      toolDescription = "列出当前会话全部 armed monitor；用返回的 m# handle 取消。",
      toolSchema = noArguments,
      toolRun = \_ -> Right . toJSON . map summarize <$> listMonitors
    }
  where
    summarize monitor =
      object
        [ "handle" .= monitorHandleText monitor.amRef.mrMonitorOrdinal,
          "goal" .= monitor.amGoal,
          "trigger" .= monitor.amTriggerKind,
          "continuation" .= monitor.amContinuationKind,
          "next_fire" .= fmap (fmtDateHM tz) monitor.amNextFireAt,
          "expires" .= fmap (fmtDateHM tz) monitor.amExpiresAt,
          "fire_count" .= monitor.amFireCount,
          "max_fires" .= monitor.amMaxFireCount
        ]

cancelMonitorTool ::
  (MonitorControl :> es) =>
  Tool es
cancelMonitorTool =
  Tool
    { toolName = "cancel_monitor",
      toolDescription = "停止 monitor 的未来触发和未受理 occurrence；默认不取消已经受理的任务。cancel_tasks=true 才额外取消在途任务。仅发起者/管理员可用。",
      toolSchema = toolObject [("handle", stringParam "例如 m#3。"), ("cancel_tasks", boolParam "是否同时取消已受理任务，默认 false。")] ["handle"],
      toolRun = \raw -> case parseEither (withObject "args" $ \fields -> (,) <$> fields .: "handle" <*> fields .:? "cancel_tasks" .!= False) raw of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right (handle, cancelTasks) -> case parseMonitorHandle handle of
          Nothing -> pure (Left "handle 格式无效，应为 m#<正整数>")
          Just ordinal -> either (Left . monitorControlErrorText) (Right . toJSON) <$> Control.controlMonitor ordinal CancelMonitor cancelTasks
    }

configureMonitorTool :: (MonitorControl :> es) => Tool es
configureMonitorTool =
  Tool
    { toolName = "configure_monitor",
      toolDescription = "按 revision 显式更新 monitor 未来 occurrence 的目标和重叠策略。旧 occurrence 保留原版本；pending_policy 必须明确 retain/cancel。queue 是每个事件都重要的有界队列，溢出记录可查，不默默丢弃。",
      toolSchema =
        toolObject
          [ ("handle", stringParam "m# 标识"),
            ("revision", integerParam "当前 revision"),
            ("goal", stringParam "未来触发的新目标"),
            ("overlap", enumParam ["coalesce", "queue"] "重叠策略"),
            ("queue_limit", boundedIntegerParam 1 160 40),
            ("pending_policy", enumParam ["retain", "cancel"] "旧版本未受理事件的处置"),
            ("profile", enumParam ["research", "browser", "sandbox", "operations"] "后台能力；operations 可继承 maxops 管理能力；始终与触发时授权取交集"),
            ("change_only", boolParam "仅稳定 observation 改变时报告")
          ]
          ["handle", "revision", "goal", "overlap", "pending_policy", "profile", "change_only"],
      toolRun = \raw -> case parseEither
        ( withObject "configure monitor" $ \fields ->
            (,,,,,,,)
              <$> fields .: "handle"
              <*> fields .: "revision"
              <*> fields .: "goal"
              <*> fields .: "overlap"
              <*> fields .:? "queue_limit" .!= 40
              <*> fields .: "pending_policy"
              <*> fields .: "profile"
              <*> fields .: "change_only"
        )
        raw of
        Left detail -> pure (Left (T.pack detail))
        Right (handle, revision, goal, overlap, capacity, pending, profile, changedOnly) -> case parseMonitorHandle handle of
          Nothing -> pure (Left "无效 m# 标识")
          Just ordinal -> case (parseOverlapPolicy overlap, parsePendingPolicy pending, parseProfile profile) of
            (Just overlapPolicy, Just pendingPolicy, Just capability) -> do
              result <- Control.controlMonitor ordinal (ConfigureMonitor revision goal overlapPolicy capacity pendingPolicy (Just (capability, changedOnly))) False
              pure $ case result of
                Left failure -> Left (monitorControlErrorText failure)
                Right receipt ->
                  Right $
                    object
                      [ "ok" .= True,
                        "revision" .= receipt.revision,
                        "admitted_tasks_cancelled" .= receipt.tasksCancelled,
                        "pending_policy" .= pending,
                        "profile" .= profile,
                        "change_only" .= changedOnly
                      ]
            _ -> pure (Left "invalid monitor definition")
    }

monitorHistoryTool :: (MonitorQuery :> es) => Tool es
monitorHistoryTool =
  Tool
    "monitor_history"
    "查看 monitor 状态、revision、下次触发和最近 150 次 fire：任务链接、合并、溢出及失败原因。"
    (toolObject [("handle", stringParam "m# 标识")] ["handle"])
    ( \raw -> case parseEither (withObject "monitor history" (.: "handle")) raw of
        Left detail -> pure (Left (T.pack detail))
        Right handle -> case parseMonitorHandle handle of
          Nothing -> pure (Left "无效 m# 标识")
          Just ordinal -> maybe (Left "monitor not found in this conversation") (Right . toJSON) <$> readMonitorHistory ordinal
    )
