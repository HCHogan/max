-- | Compatibility reminder tools backed by ADR 006 monitors. The public tool
-- names stay stable, while persistence and scheduling use @TimeCron + canned@
-- and conversation-scoped @m#@ handles.
module Max.Tools.Reminder
  ( reminderToolsFor,

    -- * Argument normalization, exported for "Max.ReminderArgsSpec"
    SetArgs (..),
    dropFiller,
    dropZero,
    resolveWhen,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone, UTCTime, addUTCTime, getCurrentTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Monitor
  ( TimeMonitor (..),
    armCannedTimeMonitor,
    listCannedTimeMonitors,
  )
import Max.DB.Task qualified as Task
import Max.Effects.Tools (Tool (..))
import Max.Monitor (nextCronFire)
import Max.Monitor.Types (MonitorOrdinal (..), MonitorRef (..), monitorHandleText, parseMonitorHandle)
import Max.Time (fmtDateHM)
import Max.ToolContext
  ( ToolContext,
    toolAuthorPrincipalId,
    toolConversationScope,
    toolGroupId,
    toolMonitorArmingAllowed,
    toolTurnOutputContext,
  )
import Max.Tools (parseTimeArg)
import Max.Tools.Schema (integerParam, noArguments, stringParam, toolObject)
import Max.Turn.Types (turnOutputAgentTurn)
import System.Cron.Parser (parseCronSchedule)

reminderToolsFor ::
  (WithConnection :> es, IOE :> es) =>
  TimeZone ->
  ToolContext ->
  [Tool es]
reminderToolsFor tz context =
  [ setReminderTool tz context,
    listRemindersTool tz context,
    cancelReminderTool context
  ]

data SetArgs = SetArgs
  { saText :: !Text,
    saInMinutes :: !(Maybe Int),
    saAt :: !(Maybe Text),
    saCron :: !(Maybe Text)
  }

setReminderTool ::
  (WithConnection :> es, IOE :> es) =>
  TimeZone ->
  ToolContext ->
  Tool es
setReminderTool tz context =
  Tool
    { toolName = "set_reminder",
      toolDescription =
        T.unwords
          [ "设一个定时提醒，到点我会主动在这个会话里 @ 你并发出提醒内容。",
            "text 是提醒内容；触发时间三选一：",
            "in_minutes（几分钟后，一次性，相对时间，优先用它以免算错）、",
            "at（一次性绝对时间 'YYYY-MM-DD HH:MM'）、",
            "cron（循环提醒的 5 段 cron 表达式）。",
            "用户说'一小时后/明天下午3点'用 in_minutes 或 at；说'每天/每周/每2小时'用 cron。"
          ],
      toolSchema =
        toolObject
          [ ("text", stringParam "提醒内容（到点原样发给用户）。"),
            ("in_minutes", integerParam "几分钟后提醒（一次性）。"),
            ("at", stringParam "一次性绝对时间：'YYYY-MM-DD HH:MM'（按机器人显示时区）。"),
            ( "cron",
              stringParam
                ( "循环提醒的 5 段 cron（分 时 日 月 周，按显示时区墙钟）。"
                    <> "例：每天9点 '0 9 * * *'；每2小时 '0 */2 * * *'；"
                    <> "每周一三五10点 '0 10 * * 1,3,5'；每月1号8点 '0 8 1 * *'。"
                )
            )
          ]
          ["text"],
      toolRun = \args -> case parseEither (withObject "args" parseSet) args of
        Left err -> pure $ Left ("bad args: " <> T.pack err)
        Right setArgs
          | T.null (T.strip setArgs.saText) -> pure (Left "text 不能为空")
          | otherwise -> do
              now <- liftIO getCurrentTime
              case resolveWhen tz setArgs now of
                Left err -> pure (Left err)
                Right (cron, fireAt) -> do
                  ref <-
                    armCannedTimeMonitor
                      (toolGroupId context)
                      (toolAuthorPrincipalId context)
                      (turnOutputAgentTurn <$> toolTurnOutputContext context)
                      (T.strip setArgs.saText)
                      cron
                      fireAt
                  pure $
                    Right $
                      object
                        [ "ok" .= True,
                          "handle" .= monitorHandleText ref.mrMonitorOrdinal,
                          "next_fire" .= fmtDateHM tz fireAt,
                          "recurring" .= isJust cron,
                          "cron" .= cron
                        ]
    }
  where
    parseSet objectValue =
      SetArgs
        <$> objectValue .: "text"
        <*> (dropZero <$> objectValue .:? "in_minutes")
        <*> (dropFiller <$> objectValue .:? "at")
        <*> (dropFiller <$> objectValue .:? "cron")

-- | Read a placeholder as the absence it means.
--
-- Models routinely fill an unused optional parameter instead of omitting it —
-- @"."@, an empty string, @0@.  None of those is a time or a cron expression,
-- so reading one as "the user asked for this specifier" turns a perfectly
-- well-formed request into a mutual-exclusion error.  That error is then
-- unrecoverable in practice: the tool writes, so a failure is reported to the
-- model as outcome-unknown, which the host prompt tells it not to retry — and
-- it re-sends the identical arguments until the turn burns out.
dropFiller :: Maybe Text -> Maybe Text
dropFiller raw = do
  value <- T.strip <$> raw
  if T.toLower value `elem` fillers then Nothing else Just value
  where
    fillers = ["", ".", "-", "null", "none", "n/a", "无"]

-- | Zero is the integer filler.  A negative stays, so it still earns the more
-- precise "必须是正整数".
dropZero :: Maybe Int -> Maybe Int
dropZero = \case
  Just 0 -> Nothing
  other -> other

resolveWhen :: TimeZone -> SetArgs -> UTCTime -> Either Text (Maybe Text, UTCTime)
resolveWhen tz setArgs now =
  case (setArgs.saInMinutes, setArgs.saAt, setArgs.saCron) of
    (Just minutes, Nothing, Nothing) -> oneShotIn minutes
    (Nothing, Just absolute, Nothing) -> oneShotAt absolute
    (Nothing, Nothing, Just cron) -> recurring cron
    (Nothing, Nothing, Nothing) -> Left "必须指定 in_minutes / at / cron 之一（只填要用的那个）"
    -- Say what to do, not just what is wrong: the previous wording named the
    -- rule and left the model to guess the remedy, and it guessed "keep the
    -- placeholders, change their values".
    _ -> Left "in_minutes / at / cron 只能给一个：不用的参数请整个省略，不要填 '.'、空字符串或 0"
  where
    oneShotIn minutes
      | minutes <= 0 = Left "in_minutes 必须是正整数"
      | minutes > 527040 = Left "in_minutes 太大了（上限约一年）"
      | otherwise = Right (Nothing, addUTCTime (fromIntegral (minutes * 60)) now)
    oneShotAt absolute = do
      time <- parseTimeArg tz absolute
      if time <= now then Left "指定的时间已经过去了" else Right (Nothing, time)
    recurring expression = case parseCronSchedule (T.strip expression) of
      Left err -> Left ("cron 表达式无效：" <> T.pack err)
      Right schedule -> case nextCronFire tz schedule now of
        Nothing -> Left "这个 cron 表达式算不出下一次触发时间"
        Just time -> Right (Just (T.strip expression), time)

listRemindersTool :: (WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> Tool es
listRemindersTool tz context =
  Tool
    { toolName = "list_reminders",
      toolDescription = "列出本会话所有还没触发的提醒（含投递重试或已暂停状态）。",
      toolSchema = noArguments,
      toolRun = \_ -> do
        monitors <- listCannedTimeMonitors (toolConversationScope context)
        pure $ Right $ toJSON (map summarize monitors)
    }
  where
    summarize monitor =
      object
        [ "handle" .= monitorHandleText monitor.tmRef.mrMonitorOrdinal,
          "next_fire" .= fmtDateHM tz monitor.tmNextFireAt,
          "status" .= status monitor,
          "next_attempt" .= fmap (fmtDateHM tz) monitor.tmNextAttemptAt,
          "delivery_attempts" .= monitor.tmDeliveryAttempts,
          "last_error" .= monitor.tmLastError,
          "text" .= monitor.tmText,
          "cron" .= monitor.tmCron,
          "fire_count" .= monitor.tmFireCount
        ]
    status monitor
      | isJust monitor.tmParkedAt = "parked" :: Text
      | isJust monitor.tmNextAttemptAt = "retrying"
      | otherwise = "scheduled"

cancelReminderTool ::
  (WithConnection :> es, IOE :> es) =>
  ToolContext ->
  Tool es
cancelReminderTool context =
  Tool
    { toolName = "cancel_reminder",
      toolDescription = "按 handle 取消一个未触发的提醒（循环提醒会就此停止）。handle 从 list_reminders 或 set_reminder 的返回里拿。",
      toolSchema = toolObject [("handle", stringParam "要取消的提醒句柄，例如 m#3。")] ["handle"],
      toolRun = \args -> case parseEither (withObject "args" (.: "handle")) args of
        Left err -> pure $ Left ("bad args: " <> T.pack err)
        Right rawHandle -> case parseMonitorHandle rawHandle of
          Nothing -> pure (Left "handle 格式无效，应为 m#<正整数>")
          Just ordinal ->
            Right
              <$> Task.monitorControl
                (toolGroupId context)
                (toolAuthorPrincipalId context)
                (toolMonitorArmingAllowed context)
                ordinal.unMonitorOrdinal
                "cancel"
                Nothing
                ""
                "coalesce"
                8
                "cancel"
                False
    }
