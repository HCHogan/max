{-# LANGUAGE TypeFamilies #-}

-- | Narrow SkillQuery capability; authority and persistence belong to its interpreter.
module Max.Effects.SkillQuery (SkillQuery, inspectSkill, runSkillQuery) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)

data SkillQuery :: Effect where
  InspectSkill :: Text -> Maybe Integer -> SkillQuery m (Either Text Value)

type instance DispatchOf SkillQuery = Dynamic

inspectSkill :: (SkillQuery :> es) => Text -> Maybe Integer -> Eff es (Either Text Value)
inspectSkill name revision = send (InspectSkill name revision)

runSkillQuery :: (Text -> Maybe Integer -> Eff es (Either Text Value)) -> Eff (SkillQuery : es) a -> Eff es a
runSkillQuery handle = interpret $ \_ -> \case
  InspectSkill name revision -> handle name revision
