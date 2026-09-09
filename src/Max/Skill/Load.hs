-- | Complete fixed dependency loading; no activation or executable tools.
module Max.Skill.Load (resolveSkillLoads) where

import Control.Monad (foldM)
import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.Skill.Package
import Max.Skills (Skill (..))
import Max.Tool.Bundles

resolveSkillLoads :: Map Text Skill -> Map Text SkillLoad -> (Text -> IO (Either Text (Maybe Value))) -> Text -> IO (Either Text [SkillLoad])
resolveSkillLoads snapshot loaded prepare = resolve snapshot [] []
  where
    resolve available seen acc name
      | Map.member name loaded || any ((== name) . (.slName)) acc = pure (Right acc)
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
