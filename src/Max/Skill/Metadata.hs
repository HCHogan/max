-- | Pure bounds shared by admin edits and model-authored drafts.
module Max.Skill.Metadata (validateSkillText) where

import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as T

maxNameLen, maxDescriptionLen, maxBodyLen :: Int
maxNameLen = 64
maxDescriptionLen = 120
maxBodyLen = 49152

-- | Shared shape check for create and patch.  'Left' is a
-- user-showable reason.
validateSkillText :: Text -> Text -> Text -> Either Text ()
validateSkillText name desc body
  | "learned-task-" `T.isPrefixOf` name = Left "learned-task- 为任务经验保留，需通过 experience 回放审核发布"
  | any (T.any (== '\0')) [name, desc, body] = Left "skill content cannot contain NUL"
  | T.null name = Left "name 不能为空"
  | T.length name > maxNameLen = Left ("name 太长（上限 " <> (T.pack . show) maxNameLen <> " 字符）")
  | T.any isSpace name = Left "name 不能含空白字符（用 - 连接）"
  | T.null (T.strip desc) = Left "description 不能为空"
  | T.length desc > maxDescriptionLen = Left ("description 太长（上限 " <> (T.pack . show) maxDescriptionLen <> " 字符，它是常驻提示词）")
  | T.any (== '\n') desc = Left "description 必须是单行"
  | T.null (T.strip body) = Left "body 不能为空"
  | T.length body > maxBodyLen = Left ("body 太长（上限 " <> (T.pack . show) maxBodyLen <> " 字符；更长的材料放 sandbox 文件）")
  | otherwise = Right ()
