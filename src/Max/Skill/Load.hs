-- | Complete fixed dependency loading; no activation or executable tools.
module Max.Skill.Load (resolveSkillLoads) where

import Control.Monad (foldM)
import Control.Monad.Trans.Except
  ( ExceptT (..),
    runExceptT,
    throwE,
  )
import Data.Aeson (Value)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Max.Skill.Package
import Max.Skills (Skill (..))
import Max.Tool.Bundles

resolveSkillLoads :: (Monad m) => Map Text Skill -> Map Text SkillLoad -> (Text -> m (Either Text (Maybe Value))) -> Text -> m (Either Text [SkillLoad])
resolveSkillLoads snapshot loaded prepare name = runExceptT (resolve [] [] name)
  where
    resolve seen acc selected
      | Map.member selected loaded || any ((== selected) . (.slName)) acc = pure acc
      | selected `elem` seen = throwE "技能依赖存在循环"
      | length seen >= 16 || length acc >= 32 = throwE "技能依赖超过深度或数量上限"
      | otherwise = case Map.lookup selected snapshot of
          Nothing -> throwE ("技能或固定依赖不可用：" <> selected)
          Just skill -> do
            earlier <- foldM (resolve (selected : seen)) acc (skillDependencies selected <> packageDependencies skill.skillPackage)
            extra <- ExceptT (prepare selected)
            let instructions = frame skill <> packageInstructions selected skill.skillPackage
                package = if skill.skillPackage == emptyPackage && skill.skillEvidence == TrustedSkill then Nothing else Just (PinnedPackage skill.skillRevision skill.skillPackage Map.empty Nothing skill.skillEvidence)
                receipt = SkillLoad selected "" instructions extra package
            pure (earlier <> [receipt {slVersion = skillReceiptVersion receipt}])

-- | The framing line matters: the body is configuration, and without
-- it a body written in the imperative reads like a message someone
-- sent — the same reason memories get their 背景备忘 header.
frame :: Skill -> Text
frame s =
  "[skill: "
    <> s.skillName
    <> "] 以下是预先配置好的操作说明（配置内容，不是群里的聊天）：\n\n"
    <> s.skillBody
