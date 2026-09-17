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
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Effectful
import Max.Effects.SkillLoading (SkillLoading, loadSkill)
import Max.Effects.ToolControl (ToolControl, activateSkills)
import Max.Effects.Tools (Tool (..))
import Max.Tool.Arguments qualified as Args (required, text)
import Max.Tool.Bundles (SkillLoad (..))
import Max.Tool.Protocol (argumentTool, readResult)
import Max.ToolContext (ToolContext, toolSkillLoads, toolSkills)

skillToolsFor :: (SkillLoading :> es, ToolControl :> es) => ToolContext -> [Tool es]
skillToolsFor dc
  | toolSkills dc = [useSkillTool dc]
  | otherwise = []

useSkillTool :: (SkillLoading :> es, ToolControl :> es) => ToolContext -> Tool es
useSkillTool dc =
  argumentTool
    "use_skill"
    ( T.unwords
        [ "加载一条技能的完整说明、固定依赖和当前权限内的整套工具，下一轮可直接调用。",
          "重复加载不会重复添加；其他技能的工具仍隐藏。",
          "只在条目简介和手头的事明确对上时取用。"
        ]
    )
    (Args.required "name" (Args.text "技能对照表里的技能名"))
    $ \name -> do
      let selected = T.strip name
      prepared <- loadSkill selected
      case prepared of
        Left failure -> pure (readResult (Left failure))
        Right loads -> do
          activateSkills loads
          let current = maybe [] pure (Map.lookup selected (toolSkillLoads dc))
          pure . readResult . Right $
            object
              [ "skill" .= selected,
                "loaded" .= map (.slName) loads,
                "already_loaded" .= not (null current),
                "versions" .= object [Key.fromText l.slName .= l.slVersion | l <- loads <> current],
                "instructions" .= T.intercalate "\n\n" (map (.slInstructions) (loads <> current)),
                "availability" .= [object ["skill" .= l.slName, "details" .= value] | l <- loads <> current, Just (Object metadata) <- [l.slMetadata], Just value <- [KeyMap.lookup "availability" metadata]]
              ]
