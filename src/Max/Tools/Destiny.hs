-- | Destiny 2 tools over the Bungie.net API. They belong to the destiny skill
-- bundle, so their schemas appear only after use_skill destiny in a
-- conversation that enabled it. Every call acts as the turn's author.
module Max.Tools.Destiny
  ( destinyToolsFor,
    readBudget,
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Ord (clamp)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.Destiny
import Max.Effects.Tools
  ( Tool (..),
    ToolFault (..),
    ToolOutcome (..),
    ToolRetryClass (..),
    ToolRunner (..),
  )
import Max.Tool.Protocol (readResult)
import Max.Tools.Schema (boundedIntegerParam, integerParam, noArguments, paramOfType, stringParam, toolObject, withKeys)

destinyToolsFor :: (Destiny :> es) => [Tool es]
destinyToolsFor = [accountTool, readTool, writeTool, lookupTool]

accountTool :: (Destiny :> es) => Tool es
accountTool =
  Tool
    { toolName = "destiny_account",
      toolDescription =
        T.unwords
          [ "发起人自己绑定的 Bungie 账号：Bungie 名、membership_type/membership_id、",
            "各角色 character_id、职业、光等和最后游玩时间。未绑定时 linked=false，",
            "按返回的 login 提示对方私聊发 !destiny login。只能查发起人自己。"
          ],
      toolSchema = noArguments,
      toolRunner = OutcomeRunner (const (ToolSucceeded <$> destinyAccount))
    }

readTool :: (Destiny :> es) => Tool es
readTool =
  Tool
    { toolName = "destiny_read",
      toolDescription =
        T.unwords
          [ "读 Bungie.net Platform 接口（GET；两个玩家搜索接口用 POST body）。",
            "自动带发起人的授权，只能读发起人自己的私有数据，别人只有公开数据。",
            "path 如 /Destiny2/3/Profile/4611…/，query 如 {\"components\": [100, 200]}。",
            "返回 Bungie 的 Response 原样，64 位 id 是字符串。Profile 等大响应只在",
            "run_code 里调用并调高 max_chars，在 JS 里筛选；可用路径和组件号见 destiny 手册。"
          ],
      toolSchema =
        toolObject
          [ ("path", stringParam "Platform 之后的路径，如 /Destiny2/3/Profile/4611686018400000000/"),
            ("query", withKeys ["description" .= ("查询参数对象；数组会写成逗号分隔" :: Text)] (paramOfType "object")),
            ("body", withKeys ["description" .= ("只用于 SearchDestinyPlayerByBungieName 和 User/Search/GlobalName" :: Text)] (paramOfType "object")),
            ("max_chars", boundedIntegerParam 1000 readBudget 60000)
          ]
          ["path"],
      toolRunner = OutcomeRunner $ \raw -> case parseEither readArgs raw of
        Left err -> pure (rejected err)
        Right (path, query, body, limit) -> readResult . fmap (bounded limit) <$> destinyRead path query body
    }
  where
    readArgs = withObject "arguments" $ \o ->
      (,,,)
        <$> o .: "path"
        <*> o .:? "query" .!= Null
        <*> o .:? "body"
        <*> (clamp (1000, readBudget) <$> o .:? "max_chars" .!= 60000)

-- | Below the 4 MiB code-mode result limit, so run_code receives it whole.
readBudget :: Int
readBudget = 3_500_000

-- A response over budget is described rather than truncated: cut JSON would
-- read as an account that lacks the missing half.
bounded :: Int -> Value -> Value
bounded limit value
  | size <= fromIntegral limit = value
  | otherwise =
      object
        [ "too_large" .= True,
          "chars" .= size,
          "max_chars" .= limit,
          "keys" .= case value of
            Object o -> map fst (KeyMap.toList o)
            _ -> [],
          "hint" .= ("在 run_code 里调用并把 max_chars 调到 3500000，或减少 components，再在 JS 里只取需要的字段" :: Text)
        ]
  where
    size = LBS.length (encode value)

writeTool :: (Destiny :> es) => Tool es
writeTool =
  Tool
    { toolName = "destiny_write",
      toolDescription =
        T.unwords
          [ "以发起人自己的账号执行物品/配装操作（POST）：转移、装备、锁定、追踪、",
            "取邮政官、免费插件、配装。只在发起人明确要求时调用；目标不唯一或会挤掉",
            "已装备物品时先复述再执行。body 的 membershipType、characterId、itemId",
            "来自 destiny_account 和 destiny_read。各接口的 body 写法见 destiny 手册。"
          ],
      toolSchema =
        toolObject
          [ ("path", stringParam "如 /Destiny2/Actions/Items/TransferItem/"),
            ("body", withKeys ["description" .= ("Bungie 请求体；64 位 id 用字符串" :: Text)] (paramOfType "object"))
          ]
          ["path", "body"],
      toolRunner = OutcomeRunner $ \raw -> case parseEither writeArgs raw of
        Left err -> pure (rejected err)
        Right (path, body) ->
          destinyWrite path body >>= \case
            WriteApplied response -> pure (ToolCommitted (object ["ok" .= True, "response" .= response]))
            WriteRefused reason -> pure (ToolFailedBeforeEffect (ToolFault "bungie_refused" reason RetrySafe))
            WriteUncertain reason -> pure (ToolOutcomeUnknown (ToolFault "bungie_unknown" reason RetryUnsafe))
    }
  where
    writeArgs = withObject "arguments" $ \o -> do
      path <- o .: "path"
      body <- o .: "body"
      case body of
        Object _ -> pure (path, body)
        _ -> fail "body 必须是对象"

lookupTool :: (Destiny :> es) => Tool es
lookupTool =
  Tool
    { toolName = "destiny_lookup",
      toolDescription =
        T.unwords
          [ "查 manifest 定义（中文名、类型、稀有度、插槽、属性等精简字段）。",
            "hashes 批量把 hash 翻译成定义（必须给 kind）；search 按中文或英文名搜，",
            "kind 可选。kind 用简称：item、plugset、stat、bucket、activity、mode、",
            "vendor、perk、record、collectible、objective、season、damage、class 等，",
            "也可写完整表名。"
          ],
      toolSchema =
        toolObject
          [ ("kind", stringParam "定义表简称或完整名"),
            ("hashes", withKeys ["items" .= object ["type" .= ("integer" :: Text)], "maxItems" .= (500 :: Int)] (integerArray "要翻译的 hash（最多 500 个）")),
            ("search", stringParam "按名字搜索（子串匹配，中英文都行）"),
            ("limit", boundedIntegerParam 1 50 10)
          ]
          [],
      toolRunner = OutcomeRunner $ \raw -> case parseEither lookupArgs raw of
        Left err -> pure (rejected err)
        Right (Left (kind, hashes)) -> readResult <$> destinyLookup kind hashes
        Right (Right (kind, term, limit)) -> readResult <$> destinySearch kind term limit
    }
  where
    integerArray description = withKeys ["type" .= ("array" :: Text)] (integerParam description)
    lookupArgs :: Value -> Parser (Either (Text, [Int64]) (Maybe Text, Text, Int))
    lookupArgs = withObject "arguments" $ \o -> do
      kind <- o .:? "kind"
      hashes <- o .:? "hashes"
      search <- o .:? "search"
      limit <- clamp (1, 50) <$> o .:? "limit" .!= 10
      case (hashes, search) of
        (Just hs, Nothing)
          | Just k <- kind, not (null hs), length hs <= 500 -> pure (Left (k, hs))
          | Nothing <- kind -> fail "按 hash 查需要 kind"
          | otherwise -> fail "hashes 需要 1–500 个"
        (Nothing, Just term)
          | not (T.null (T.strip term)) -> pure (Right (kind, term, limit))
        _ -> fail "hashes 和 search 二选一"

rejected :: String -> ToolOutcome
rejected err = ToolRejected (ToolFault "invalid_arguments" (T.pack err) RetrySafe)
