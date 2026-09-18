-- | Bind the current conversation before handing a loader to tools.
module Max.Skill.ToolRuntime (skillToolsWithRuntime) where

import Data.Aeson (Value)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful
import Max.Effects.SkillLoading (runSkillLoading)
import Max.Effects.ToolControl (ToolControl)
import Max.Effects.Tools (Tool, hoistTool)
import Max.Skill.Load (resolveSkillLoads)
import Max.Skills
import Max.Tool.Bundles (SkillLoad (..), checkSkillLoadBudget)
import Max.ToolContext
import Max.Tools.Skills (skillToolsFor)

skillToolsWithRuntime :: (IOE :> es, ToolControl :> es) => SkillRegistry -> ToolContext -> (Text -> IO (Either Text (Maybe Value))) -> ([SkillLoad] -> Either Text [SkillLoad]) -> [Tool es]
skillToolsWithRuntime registry context prepare bind = map (hoistTool (runSkillLoading resolve)) (skillToolsFor context)
  where
    resolve name = do
      snapshot <- liftIO (skillsForGroup registry (toolGroupId context))
      loaded <- liftIO (resolveSkillLoads (Map.fromList [(s.skillName, s) | s <- snapshot]) (toolSkillLoads context) prepare name)
      pure (loaded >>= bind >>= checkSkillLoadBudget (toolSkillLoads context))
