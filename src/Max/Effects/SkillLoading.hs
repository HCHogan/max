{-# LANGUAGE TypeFamilies #-}

-- | Resolve a skill in the host-bound conversation and catalog. Registry access,
-- dependency preparation and authority checks belong to the supplied interpreter.
module Max.Effects.SkillLoading (SkillLoading, loadSkill, runSkillLoading) where

import Data.Text (Text)
import Effectful
  ( Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    type (:>),
  )
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Tool.Bundles (SkillLoad)

data SkillLoading :: Effect where
  LoadSkill :: Text -> SkillLoading m (Either Text [SkillLoad])

type instance DispatchOf SkillLoading = Dynamic

loadSkill :: (SkillLoading :> es) => Text -> Eff es (Either Text [SkillLoad])
loadSkill = send . LoadSkill

runSkillLoading :: (Text -> Eff es (Either Text [SkillLoad])) -> Eff (SkillLoading : es) a -> Eff es a
runSkillLoading resolve = interpret $ \_ -> \case
  LoadSkill name -> resolve name
