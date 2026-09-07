-- |
-- @use_skill@: turn a 技能对照表 entry into its full instructions.
-- The index the model reads is rendered into the system prompt from
-- the same registry this tool queries, so a listed name always
-- resolves — a miss means the model invented one, and the error
-- carries the valid names to steer it back.
--
-- Registration is gated on the dispatch actually having skills
-- visible ('Max.ToolContext.toolSkills'): a group with none pays no
-- schema tokens for a tool that could only fail.
module Max.Tools.Skills
  ( skillToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.ToolControl (ToolControl, activateSkills)
import Max.Effects.Tools (Tool (..))
import Max.Skills (Skill (..), SkillRegistry, lookupSkill, skillsForGroup)
import Max.Tool.Bundles (SkillLoad (..), skillDependencies, skillLoadVersion)
import Max.ToolContext (ToolContext, toolGroupId, toolSkillLoads, toolSkills)
import Max.Tools.Schema (stringParam, toolObject)

skillToolsFor :: (IOE :> es, ToolControl :> es) => SkillRegistry -> ToolContext -> (Text -> IO (Either Text (Maybe Value))) -> [Tool es]
skillToolsFor reg dc prepare
  | toolSkills dc = [useSkillTool reg dc prepare]
  | otherwise = []

useSkillTool :: (IOE :> es, ToolControl :> es) => SkillRegistry -> ToolContext -> (Text -> IO (Either Text (Maybe Value))) -> Tool es
useSkillTool reg dc prepare =
  Tool
    { toolName = "use_skill",
      toolDescription =
        T.unwords
          [ "加载一条技能的完整说明、固定依赖和当前权限内的整套工具，下一轮可直接调用。",
            "重复加载不会重复添加；其他技能的工具仍隐藏。",
            "只在条目简介和手头的事明确对上时取用。"
          ],
      toolSchema = toolObject [("name", stringParam "技能对照表里的技能名")] ["name"],
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "name")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (name :: Text) -> do
          found <- liftIO (lookupSkill reg (toolGroupId dc) (T.strip name))
          case found of
            Just s -> do
              prepared <- liftIO (resolve [] s)
              case prepared of
                Left failure -> pure (Left failure)
                Right loads
                  | sum (map (T.length . (.slInstructions)) loads) + sum (map (T.length . (.slInstructions)) (Map.elems (toolSkillLoads dc))) > 120000
                      || LBS.length (encode loads) > 512000 ->
                      pure (Left "技能包超过完整加载上限；请缩小技能说明或在设计中拆分固定工具包，不能静默截断")
                Right loads -> do
                  activateSkills loads
                  pure . Right $
                    object
                      [ "skill" .= s.skillName,
                        "loaded" .= map (.slName) loads,
                        "already_loaded" .= Map.member s.skillName (toolSkillLoads dc),
                        "instructions" .= T.intercalate "\n\n" (map (.slInstructions) loads),
                        "availability"
                          .= [ object ["skill" .= load.slName, "details" .= available]
                             | load <- loads,
                               Just (Object metadata) <- [load.slMetadata],
                               Just available <- [KeyMap.lookup "availability" metadata]
                             ]
                      ]
            Nothing -> do
              skills <- liftIO (skillsForGroup reg (toolGroupId dc))
              pure . Left $
                "没有叫 '"
                  <> name
                  <> "' 的技能。可用的技能："
                  <> T.intercalate "、" [s.skillName | s <- skills]
    }
  where
    resolve seen s
      | Map.member s.skillName (toolSkillLoads dc) = pure (Right [])
      | s.skillName `elem` seen = pure (Left "技能依赖存在循环")
      | otherwise = do
          dependencies <- traverse (lookupSkill reg (toolGroupId dc)) (skillDependencies s.skillName)
          case sequence dependencies of
            Nothing -> pure (Left "技能的固定依赖不可用")
            Just available -> do
              nested <- traverse (resolve (s.skillName : seen)) available
              metadata <- prepare s.skillName
              pure $ do
                earlier <- concat <$> sequence nested
                extra <- metadata
                let instructions = frame s
                Right (earlier <> [SkillLoad s.skillName (skillLoadVersion instructions) instructions extra])

-- | The framing line matters: the body is configuration, and without
-- it a body written in the imperative reads like a message someone
-- sent — the same reason memories get their 背景备忘 header.
frame :: Skill -> Text
frame s =
  "[skill: "
    <> s.skillName
    <> "] 以下是预先配置好的操作说明（配置内容，不是群里的聊天）：\n\n"
    <> s.skillBody
