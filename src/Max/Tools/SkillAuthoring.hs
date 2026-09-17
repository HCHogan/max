-- | Model protocol only. Each operation has its own narrow capability.
module Max.Tools.SkillAuthoring (skillAuthoringTools) where

import Data.Aeson
import Effectful
import Max.Effects.SkillDraft
import Max.Effects.SkillPublication
import Max.Effects.SkillQuery
import Max.Effects.SkillValidation
import Max.Effects.Tools (Tool)
import Max.Skill.Authoring (DraftContent (..), DraftVersion (..))
import Max.Tool.Arguments qualified as Args
  ( decodedObject,
    integer,
    optional,
    required,
    text,
  )
import Max.Tool.Protocol
  ( argumentTool,
    committedResult,
    readResult,
  )

skillAuthoringTools :: (SkillDraft :> es, SkillQuery :> es, SkillValidation :> es, SkillPublication :> es) => [Tool es]
skillAuthoringTools =
  [ argumentTool
      "skill_save"
      "在当前群保存不可变草稿，不发布。expected_revision=0 表示首次创建；内容与 fixtures 格式见 skill-authoring。"
      ( (,)
          <$> Args.required "draft" (Args.decodedObject "完整的 name,description,body,package,fixtures，格式见 skill-authoring")
          <*> Args.required "expected_revision" (Args.integer "观察到的草稿版本，新建为 0")
      )
      (\(draft, expected) -> committedResult . fmap (\v -> object ["name" .= v.dvContent.dcName, "revision" .= v.dvRevision, "published" .= False]) <$> saveSkillDraft draft expected),
    argumentTool
      "skill_inspect"
      "查看当前群 skill 的草稿、发布版本和校验记录；传 revision 才返回该草稿完整源码、fixtures 和相对上一草稿的变更摘要。"
      ((,) <$> name <*> Args.optional "revision" (Args.integer "可选：读取精确草稿版本"))
      (\(selected, revision) -> readResult <$> inspectSkill selected revision),
    argumentTool
      "skill_validate"
      "用隔离的模拟工具运行指定草稿的 fixtures，保存绑定版本与工具契约的报告。不会执行真实工具。"
      ((,) <$> name <*> Args.required "revision" (Args.integer "精确草稿版本"))
      (\(selected, revision) -> committedResult <$> validateSkillDraft selected revision),
    argumentTool
      "skill_publish"
      "发布当前群已通过校验的精确草稿，重新检查调用者与依赖契约。expected_revision 是当前已发布版本，新建为 0。"
      ( (,,,)
          <$> name
          <*> Args.required "revision" (Args.integer "草稿版本")
          <*> Args.required "validation_id" (Args.integer "成功校验记录")
          <*> Args.required "expected_revision" (Args.integer "观察到的发布版本，新建为 0")
      )
      (\(selected, revision, proof, expected) -> committedResult <$> publishSkillDraft selected revision proof expected)
  ]
  where
    name = Args.required "name" (Args.text "当前群自建 skill 名")
