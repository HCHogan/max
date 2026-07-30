-- |
-- @use_skill@: turn a 技能对照表 entry into its full instructions.
-- The index the model reads is rendered into the system prompt from
-- the same registry this tool queries, so a listed name always
-- resolves — a miss means the model invented one, and the error
-- carries the valid names to steer it back.
--
-- Registration is gated on the dispatch actually having skills
-- visible ('Max.Effects.Agent.dcSkills'): a group with none pays no
-- schema tokens for a tool that could only fail.
module Max.Tools.Skills
  ( skillToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (parseEither)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Max.Effects.Agent (DispatchContext (..))
import Max.Effects.Tools (Tool (..))
import Max.Skills (Skill (..), SkillRegistry, lookupSkill, skillsForGroup)

skillToolsFor :: IOE :> es => SkillRegistry -> DispatchContext -> [Tool es]
skillToolsFor reg dc
  | dc.dcSkills = [useSkillTool reg dc]
  | otherwise = []

useSkillTool :: IOE :> es => SkillRegistry -> DispatchContext -> Tool es
useSkillTool reg dc =
  Tool
    { toolName = "use_skill",
      toolDescription =
        T.unwords
          [ "取一条技能的完整说明（系统提示里技能对照表条目的全文）。",
            "说明是预先写好的操作流程，取到后照着做。",
            "只在条目简介和手头的事明确对上时取用。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "name"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "description" .= ("技能对照表里的技能名" :: Text)
                      ]
                ],
            "required" .= (["name"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" (\o -> o .: "name")) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right (name :: Text) -> do
          found <- liftIO (lookupSkill reg dc.dcGroupId (T.strip name))
          case found of
            Just s ->
              pure . Right $
                object
                  [ "skill" .= s.skillName,
                    "instructions" .= frame s
                  ]
            Nothing -> do
              skills <- liftIO (skillsForGroup reg dc.dcGroupId)
              pure . Left $
                "没有叫 '"
                  <> name
                  <> "' 的技能。可用的技能："
                  <> T.intercalate "、" [s.skillName | s <- skills]
    }

-- | The framing line matters: the body is configuration, and without
-- it a body written in the imperative reads like a message someone
-- sent — the same reason memories get their 背景备忘 header.
frame :: Skill -> Text
frame s =
  "[skill: "
    <> s.skillName
    <> "] 以下是预先配置好的操作说明（配置内容，不是群里的聊天）：\n\n"
    <> s.skillBody
