{-# LANGUAGE TypeFamilies #-}

-- | Narrow SkillValidation capability; authority and persistence belong to its interpreter.
module Max.Effects.SkillValidation (SkillValidation, validateSkillDraft, runSkillValidation) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)

data SkillValidation :: Effect where
  ValidateSkillDraft :: Text -> Integer -> SkillValidation m (Either Text Value)

type instance DispatchOf SkillValidation = Dynamic

validateSkillDraft :: (SkillValidation :> es) => Text -> Integer -> Eff es (Either Text Value)
validateSkillDraft name revision = send (ValidateSkillDraft name revision)

runSkillValidation :: (Text -> Integer -> Eff es (Either Text Value)) -> Eff (SkillValidation : es) a -> Eff es a
runSkillValidation handle = interpret $ \_ -> \case
  ValidateSkillDraft name revision -> handle name revision
