-- |
-- Agent-facing reminder tools: set a one-shot or recurring reminder,
-- list this conversation's pending reminders, and cancel one.  The
-- delivery/scheduling machinery lives in "Max.Reminder"; the persistence
-- in "Max.DB.Reminder".  These tools only parse arguments, resolve the
-- fire time, and poke the scheduler awake.
--
-- The conversation is implicit: group/user/self come from the
-- 'ToolContext', so the model never passes ids.
module Max.Tools.Reminder
  ( reminderToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (TimeZone, UTCTime, addUTCTime, getCurrentTime)
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Reminder
  ( Reminder (..),
    cancelReminder,
    insertReminder,
    listPending,
  )
import Max.Effects.Tools (Tool (..))
import Max.Reminder (ReminderScheduler, nextCronFire, notifyReminderChange)
import Max.Time (fmtDateHM)
import Max.Tools (parseTimeArg)
import Max.ToolContext (ToolContext, toolGroupId, toolSelfId, toolUserId)
import System.Cron.Parser (parseCronSchedule)

reminderToolsFor ::
  (WithConnection :> es, IOE :> es) =>
  TimeZone ->
  ReminderScheduler ->
  ToolContext ->
  [Tool es]
reminderToolsFor tz sched dc =
  [ setReminderTool tz sched dc,
    listRemindersTool tz dc,
    cancelReminderTool sched dc
  ]

--------------------------------------------------------------------------------
-- set_reminder

data SetArgs = SetArgs
  { saText :: !Text,
    saInMinutes :: !(Maybe Int),
    saAt :: !(Maybe Text),
    saCron :: !(Maybe Text)
  }

setReminderTool ::
  (WithConnection :> es, IOE :> es) =>
  TimeZone ->
  ReminderScheduler ->
  ToolContext ->
  Tool es
setReminderTool tz sched dc =
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
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "text"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("提醒内容（到点原样发给用户）。" :: Text)
                      ],
                  "in_minutes"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("几分钟后提醒（一次性）。" :: Text)
                      ],
                  "at"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("一次性绝对时间：'YYYY-MM-DD HH:MM'（按机器人显示时区）。" :: Text)
                      ],
                  "cron"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description"
                          .= ( "循环提醒的 5 段 cron（分 时 日 月 周，按显示时区墙钟）。"
                                 <> "例：每天9点 '0 9 * * *'；每2小时 '0 */2 * * *'；"
                                 <> "每周一三五10点 '0 10 * * 1,3,5'；每月1号8点 '0 8 1 * *'。" ::
                                 Text
                             )
                      ]
                ],
            "required" .= (["text"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseSet) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right sa -> do
          now <- liftIO getCurrentTime
          case resolveWhen tz sa now of
            Left e -> pure $ Left e
            Right (cron, fireAt) -> do
              rid <-
                insertReminder
                  (toolGroupId dc)
                  (toolUserId dc)
                  (toolSelfId dc)
                  (T.strip sa.saText)
                  cron
                  fireAt
              liftIO (notifyReminderChange sched)
              pure $
                Right $
                  object
                    [ "ok" .= True,
                      "id" .= rid,
                      "next_fire" .= fmtDateHM tz fireAt,
                      "recurring" .= isJust cron,
                      "cron" .= cron
                    ]
    }
  where
    parseSet o =
      SetArgs
        <$> o .: "text"
        <*> o .:? "in_minutes"
        <*> o .:? "at"
        <*> o .:? "cron"

-- | Resolve the (cron, first-fire) pair from exactly one of the three
-- time specifiers.  Left is a model-facing error string.
resolveWhen :: TimeZone -> SetArgs -> UTCTime -> Either Text (Maybe Text, UTCTime)
resolveWhen tz sa now =
  case (sa.saInMinutes, sa.saAt, sa.saCron) of
    (Just m, Nothing, Nothing) -> oneShotIn m
    (Nothing, Just s, Nothing) -> oneShotAt s
    (Nothing, Nothing, Just c) -> recurring c
    (Nothing, Nothing, Nothing) -> Left "必须指定 in_minutes / at / cron 之一"
    _ -> Left "in_minutes / at / cron 只能给一个"
  where
    oneShotIn m
      | m <= 0 = Left "in_minutes 必须是正整数"
      | m > 527040 = Left "in_minutes 太大了（上限约一年）"
      | otherwise = Right (Nothing, addUTCTime (fromIntegral (m * 60)) now)
    oneShotAt s = do
      t <- parseTimeArg tz s
      if t <= now then Left "指定的时间已经过去了" else Right (Nothing, t)
    recurring c = case parseCronSchedule (T.strip c) of
      Left e -> Left ("cron 表达式无效：" <> T.pack e)
      Right sched -> case nextCronFire tz sched now of
        Nothing -> Left "这个 cron 表达式算不出下一次触发时间"
        Just t -> Right (Just (T.strip c), t)

--------------------------------------------------------------------------------
-- list_reminders

listRemindersTool :: (WithConnection :> es, IOE :> es) => TimeZone -> ToolContext -> Tool es
listRemindersTool tz dc =
  Tool
    { toolName = "list_reminders",
      toolDescription = "列出本会话所有还没触发的提醒（含 id、下次触发时间、内容，循环的还有 cron）。",
      toolSchema = object ["type" .= ("object" :: Text), "properties" .= object []],
      toolRun = \_ -> do
        rs <- listPending (toolGroupId dc)
        pure $ Right $ toJSON (map summarize rs)
    }
  where
    summarize r =
      object
        [ "id" .= r.rmId,
          "next_fire" .= fmtDateHM tz r.rmFireAt,
          "text" .= r.rmText,
          "cron" .= r.rmCron
        ]

--------------------------------------------------------------------------------
-- cancel_reminder

cancelReminderTool :: (WithConnection :> es, IOE :> es) => ReminderScheduler -> ToolContext -> Tool es
cancelReminderTool sched dc =
  Tool
    { toolName = "cancel_reminder",
      toolDescription = "按 id 取消一个未触发的提醒（循环提醒会就此停止）。id 从 list_reminders 或 set_reminder 的返回里拿。",
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("要取消的提醒 id。" :: Text)
                      ]
                ],
            "required" .= (["id"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" (.: "id")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (rid :: Int64) -> do
          ok <- cancelReminder (toolGroupId dc) rid
          if ok
            then do
              liftIO (notifyReminderChange sched)
              pure $ Right $ object ["ok" .= True, "cancelled" .= rid]
            else
              pure $
                Right $
                  object
                    [ "ok" .= False,
                      "error" .= ("没有找到这个提醒（可能已触发，或不属于本会话）" :: Text)
                    ]
    }
