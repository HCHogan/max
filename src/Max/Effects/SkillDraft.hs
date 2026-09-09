{-# LANGUAGE TypeFamilies #-}

-- | Narrow SkillDraft capability; authority and persistence belong to its interpreter.
module Max.Effects.SkillDraft (SkillDraft, saveSkillDraft, runSkillDraft) where

import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Skill.Authoring (DraftContent, DraftVersion)

data SkillDraft :: Effect where
  SaveSkillDraft :: DraftContent -> Integer -> SkillDraft m (Either Text DraftVersion)

type instance DispatchOf SkillDraft = Dynamic

saveSkillDraft :: (SkillDraft :> es) => DraftContent -> Integer -> Eff es (Either Text DraftVersion)
saveSkillDraft draft expected = send (SaveSkillDraft draft expected)

runSkillDraft :: (DraftContent -> Integer -> Eff es (Either Text DraftVersion)) -> Eff (SkillDraft : es) a -> Eff es a
runSkillDraft handle = interpret $ \_ -> \case
  SaveSkillDraft draft expected -> handle draft expected
