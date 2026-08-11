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
import Data.Time (TimeZone, UTCTime, addUTCTime, getCurrentTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Monitor
import Max.Effects.Tools (Tool (..))
import Max.IR (MediaKind (..))
import Max.Monitor (nextCronFire)
import Max.Monitor.Types
import Max.Platform.Types (PrincipalId (..))
import Max.Time (fmtDateHM)
import Max.ToolContext
import Max.Tools (parseTimeArg)
import Max.Tools.Schema (boolParam, boundedIntegerParam, enumParam, integerParam, noArguments, stringParam, toolObject)
import Max.Turn.Types (turnOutputAgentTurn)
import System.Cron.Parser (parseCronSchedule)

monitorToolsFor ::
  (WithConnection :> es, IOE :> es) =>
  TimeZone ->
  ToolContext ->
  [Tool es]
monitorToolsFor tz context =
  [armMonitorTool tz context, listMonitorsTool tz context, cancelMonitorTool context]

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
  (WithConnection :> es, IOE :> es) =>
  TimeZone ->
  ToolContext ->
  Tool es
armMonitorTool tz context =
  Tool
    { toolName = "arm_monitor",
      toolDescription =
        "武装一个会在条件满足后开启新普通回合的 monitor。trigger=time 用 in_minutes/at/cron；trigger=ledger 用 sender_principal、text_contains、media_kind、mention_self 中至少一个。条件只观察武装后的 live 入站，历史导入不会触发。",
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
            ("ttl_days", boundedIntegerParam 1 365 30),
            ("max_fires", boundedIntegerParam 1 20 20)
          ]
          ["goal", "trigger"],
      toolRun = \raw -> case parseEither (withObject "args" parseArm) raw of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right args
          | not (toolMonitorArmingAllowed context) -> pure (Left "当前角色无权武装会主动发起回合的 monitor")
          | T.null (T.strip args.aaGoal) -> pure (Left "goal 不能为空")
          | args.aaCooldownSeconds < 0 || args.aaCooldownSeconds > 86400 -> pure (Left "cooldown_seconds 必须在 0..86400")
          | args.aaTtlDays < 1 || args.aaTtlDays > 365 -> pure (Left "ttl_days 必须在 1..365")
          | args.aaMaxFires < 1 || args.aaMaxFires > 20 -> pure (Left "max_fires 必须在 1..20")
          | Nothing <- toolTurnOutputContext context -> pure (Left "当前回合缺少可持久化的 arming-turn provenance")
          | otherwise -> do
              let Just outputContext = toolTurnOutputContext context
                  armingTurn = turnOutputAgentTurn outputContext
                  effectCeiling = toolCatalogGrants context
              now <- liftIO getCurrentTime
              case args.aaTrigger of
                "time" -> case resolveTime tz args now of
                  Left err -> pure (Left err)
                  Right (cron, fireAt) -> do
                    armed <-
                      armElaboratedTimeMonitor
                        (toolGroupId context)
                        (toolAuthorPrincipalId context)
                        armingTurn
                        (T.strip args.aaGoal)
                        cron
                        fireAt
                        effectCeiling
                    pure (armResult tz fireAt cron armed)
                "ledger" -> case ledgerSpec args of
                  Left err -> pure (Left err)
                  Right spec -> do
                    let expires = addUTCTime (fromIntegral (args.aaTtlDays * 86400)) now
                    armed <-
                      armLedgerMatchMonitor
                        (toolGroupId context)
                        (toolAuthorPrincipalId context)
                        armingTurn
                        (T.strip args.aaGoal)
                        spec
                        args.aaCooldownSeconds
                        expires
                        args.aaMaxFires
                        effectCeiling
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
        <*> (fromMaybe 30 <$> o .:? "ttl_days")
        <*> (fromMaybe 20 <$> o .:? "max_fires")

resolveTime :: TimeZone -> ArmArgs -> UTCTime -> Either Text (Maybe Text, UTCTime)
resolveTime tz args now = case (args.aaInMinutes, args.aaAt, args.aaCron) of
  (Just minutes, Nothing, Nothing)
    | minutes <= 0 -> Left "in_minutes 必须是正整数"
    | minutes > 527040 -> Left "in_minutes 太大了（上限约一年）"
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

armErrorText :: MonitorArmError -> Text
armErrorText = \case
  ArmedMonitorCapReached -> "本会话已达到 20 个 armed monitor 上限"
  ConditionMonitorCapReached -> "本会话已达到 5 个 condition monitor 上限"
  ArmingTurnOutsideConversation -> "arming turn 不属于当前会话"

listMonitorsTool :: (WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> Tool es
listMonitorsTool tz context =
  Tool
    { toolName = "list_monitors",
      toolDescription = "列出当前会话全部 armed monitor；用返回的 m# handle 取消。",
      toolSchema = noArguments,
      toolRun = \_ -> do
        monitors <- listArmedMonitors (toolConversationScope context)
        pure $ Right $ toJSON (map summarize monitors)
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
  (WithConnection :> es, IOE :> es) =>
  ToolContext ->
  Tool es
cancelMonitorTool context =
  Tool
    { toolName = "cancel_monitor",
      toolDescription = "按当前会话里的 m# handle 取消一个 armed monitor。",
      toolSchema = toolObject [("handle", stringParam "例如 m#3。")] ["handle"],
      toolRun = \raw -> case parseEither (withObject "args" (.: "handle")) raw of
        Left err -> pure (Left ("bad args: " <> T.pack err))
        Right handle -> case parseMonitorHandle handle of
          Nothing -> pure (Left "handle 格式无效，应为 m#<正整数>")
          Just ordinal -> do
            cancelled <- cancelMonitor (toolConversationScope context) ordinal
            pure $
              Right $
                object
                  [ "ok" .= cancelled,
                    "cancelled" .= if cancelled then Just (monitorHandleText ordinal) else Nothing
                  ]
    }
