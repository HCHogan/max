-- | Model protocol only. Each operation has its own narrow capability.
module Max.Tools.SkillAuthoring (skillAuthoringTools) where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.SkillDraft
import Max.Effects.SkillPublication
import Max.Effects.SkillQuery
import Max.Effects.SkillValidation
import Max.Effects.Tools (Tool (..))
import Max.Skill.Authoring (DraftContent (..), DraftVersion (..))
import Max.Tools.Schema (integerParam, stringParam, toolObject)

skillAuthoringTools :: (SkillDraft :> es, SkillQuery :> es, SkillValidation :> es, SkillPublication :> es) => [Tool es]
skillAuthoringTools =
  [ Tool
      "skill_save"
      "在当前群保存不可变草稿，不发布。expected_revision=0 表示首次创建；内容与 fixtures 格式见 skill-authoring。"
      (toolObject [("draft", object ["type" .= ("object" :: Text), "description" .= ("完整的 name,description,body,package,fixtures，格式见 skill-authoring" :: Text)]), ("expected_revision", integerParam "观察到的草稿版本，新建为 0")] ["draft", "expected_revision"])
      ( \args -> case parseEither (withObject "args" (\o -> (,) <$> o .: "draft" <*> o .: "expected_revision")) args of
          Left err -> pure (Left (T.pack err))
          Right (draft, expected) -> fmap (\v -> object ["name" .= v.dvContent.dcName, "revision" .= v.dvRevision, "published" .= False]) <$> saveSkillDraft draft expected
      ),
    Tool
      "skill_inspect"
      "查看当前群 skill 的草稿、发布版本和校验记录；传 revision 才返回该草稿完整源码、fixtures 和相对上一草稿的变更摘要。"
      (toolObject [("name", nameParam), ("revision", integerParam "可选：读取精确草稿版本")] ["name"])
      ( \args -> case parseEither (withObject "args" (\o -> (,) <$> o .: "name" <*> o .:? "revision")) args of
          Left err -> pure (Left (T.pack err))
          Right (name, revision) -> inspectSkill name revision
      ),
    Tool
      "skill_validate"
      "用隔离的模拟工具运行指定草稿的 fixtures，保存绑定版本与工具契约的报告。不会执行真实工具。"
      (toolObject [("name", nameParam), ("revision", integerParam "精确草稿版本")] ["name", "revision"])
      ( \args -> case parseEither (withObject "args" (\o -> (,) <$> o .: "name" <*> o .: "revision")) args of
          Left err -> pure (Left (T.pack err))
          Right (name, revision) -> validateSkillDraft name revision
      ),
    Tool
      "skill_publish"
      "发布当前群已通过校验的精确草稿，重新检查调用者与依赖契约。expected_revision 是当前已发布版本，新建为 0。"
      (toolObject [("name", nameParam), ("revision", integerParam "草稿版本"), ("validation_id", integerParam "成功校验记录"), ("expected_revision", integerParam "观察到的发布版本，新建为 0")] ["name", "revision", "validation_id", "expected_revision"])
      ( \args -> case parseEither (withObject "args" (\o -> (,,,) <$> o .: "name" <*> o .: "revision" <*> o .: "validation_id" <*> o .: "expected_revision")) args of
          Left err -> pure (Left (T.pack err))
          Right (name, revision, proof, expected) -> publishSkillDraft name revision proof expected
      )
  ]
  where
    nameParam = stringParam "当前群自建 skill 名"
