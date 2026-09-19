-- | Host-authored skill activation, separate from ordinary tool results.
module Max.Tool.Control (LoopControl (..), mergeControls, controlSkillLoads) where

import Max.Tool.Bundles (SkillLoad)

data LoopControl = ContinueLoop | LoadSkills ![SkillLoad]
  deriving stock (Eq, Show)

mergeControls :: [LoopControl] -> LoopControl
mergeControls decisions = case concatMap controlSkillLoads decisions of
  [] -> ContinueLoop
  loads -> LoadSkills loads

controlSkillLoads :: LoopControl -> [SkillLoad]
controlSkillLoads ContinueLoop = []
controlSkillLoads (LoadSkills loads) = loads
