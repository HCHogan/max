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

import Control.Monad (foldM)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.ToolControl (ToolControl, activateSkills)
import Max.Effects.Tools (Tool (..))
import Max.Skill.Package (PinnedPackage (..), emptyPackage, packageDependencies, packageInstructions)
import Max.Skills (Skill (..), SkillRegistry, skillsForGroup)
import Max.Tool.Bundles (SkillLoad (..), skillDependencies, skillReceiptVersion)
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
          prepared <- liftIO (resolve available [] [] selected)
          case prepared >>= bind of
            Left failure -> pure (Left failure)
            Right loads
              | length loads + Map.size (toolSkillLoads dc) > 32
                  || sum (map (T.length . (.slInstructions)) (loads <> Map.elems (toolSkillLoads dc))) > 120000
                  || LBS.length (encode (loads <> Map.elems (toolSkillLoads dc))) > 512000 ->
                  pure (Left "技能包超过完整加载上限，不能静默截断")
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
  where
    resolve available seen acc name
      | Map.member name (toolSkillLoads dc) || any ((== name) . (.slName)) acc = pure (Right acc)
      | name `elem` seen = pure (Left "技能依赖存在循环")
      | length seen >= 16 || length acc >= 32 = pure (Left "技能依赖超过深度或数量上限")
      | otherwise = case Map.lookup name available of
          Nothing -> pure (Left ("技能或固定依赖不可用：" <> name))
          Just s -> do
            nested <-
              foldM
                ( \result dependency -> case result of
                    Left err -> pure (Left err)
                    Right earlier -> resolve available (name : seen) earlier dependency
                )
                (Right acc)
                (skillDependencies name <> packageDependencies s.skillPackage)
            case nested of
              Left err -> pure (Left err)
              Right earlier -> do
                metadata <- prepare name
                pure $ do
                  extra <- metadata
                  let instructions = frame s <> packageInstructions name s.skillPackage
                      load = SkillLoad name "" instructions extra (if s.skillPackage == emptyPackage then Nothing else Just (PinnedPackage s.skillRevision s.skillPackage Map.empty))
                  Right (earlier <> [load {slVersion = skillReceiptVersion load}])

-- | The framing line matters: the body is configuration, and without
-- it a body written in the imperative reads like a message someone
-- sent — the same reason memories get their 背景备忘 header.
frame :: Skill -> Text
frame s =
  "[skill: "
    <> s.skillName
    <> "] 以下是预先配置好的操作说明（配置内容，不是群里的聊天）：\n\n"
    <> s.skillBody
