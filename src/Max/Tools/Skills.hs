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
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.ToolControl (ToolControl, activateSkills)
import Max.Effects.Tools (Tool (..))
import Max.Skill.Load (resolveSkillLoads)
import Max.Skills (Skill (..), SkillRegistry, skillsForGroup)
import Max.Tool.Bundles (SkillLoad (..), checkSkillLoadBudget)
import Max.ToolContext (ToolContext, toolGroupId, toolSkillLoads, toolSkills)
import Max.Tools.Schema (stringParam, toolObject)

skillToolsFor :: (IOE :> es, ToolControl :> es) => SkillRegistry -> ToolContext -> (Text -> IO (Either Text (Maybe Value))) -> ([SkillLoad] -> Either Text [SkillLoad]) -> [Tool es]
skillToolsFor reg dc prepare bind
  | toolSkills dc = [useSkillTool reg dc prepare bind]
  | otherwise = []

useSkillTool :: (IOE :> es, ToolControl :> es) => SkillRegistry -> ToolContext -> (Text -> IO (Either Text (Maybe Value))) -> ([SkillLoad] -> Either Text [SkillLoad]) -> Tool es
useSkillTool reg dc prepare bind =
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
          snapshot <- liftIO (skillsForGroup reg (toolGroupId dc))
          let available = Map.fromList [(s.skillName, s) | s <- snapshot]
              selected = T.strip name
          prepared <- liftIO (resolveSkillLoads available (toolSkillLoads dc) prepare selected)
          case prepared >>= bind >>= checkSkillLoadBudget (toolSkillLoads dc) of
            Left failure -> pure (Left failure)
            Right loads -> do
              activateSkills loads
              let current = maybe [] pure (Map.lookup selected (toolSkillLoads dc))
              pure . Right $
                object
                  [ "skill" .= selected,
                    "loaded" .= map (.slName) loads,
                    "already_loaded" .= not (null current),
                    "versions" .= object [Key.fromText l.slName .= l.slVersion | l <- loads <> current],
                    "instructions" .= T.intercalate "\n\n" (map (.slInstructions) (loads <> current)),
                    "availability" .= [object ["skill" .= l.slName, "details" .= value] | l <- loads <> current, Just (Object metadata) <- [l.slMetadata], Just value <- [KeyMap.lookup "availability" metadata]]
                  ]
    }
