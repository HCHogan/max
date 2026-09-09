{-# LANGUAGE TypeFamilies #-}

-- | Narrow SkillPublication capability; authority and persistence belong to its interpreter.
module Max.Effects.SkillPublication (SkillPublication, publishSkillDraft, runSkillPublication) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)

data SkillPublication :: Effect where
  PublishSkillDraft :: Text -> Integer -> Integer -> Integer -> SkillPublication m (Either Text Value)

type instance DispatchOf SkillPublication = Dynamic

publishSkillDraft :: (SkillPublication :> es) => Text -> Integer -> Integer -> Integer -> Eff es (Either Text Value)
publishSkillDraft name revision validation expected = send (PublishSkillDraft name revision validation expected)

runSkillPublication :: (Text -> Integer -> Integer -> Integer -> Eff es (Either Text Value)) -> Eff (SkillPublication : es) a -> Eff es a
runSkillPublication handle = interpret $ \_ -> \case
  PublishSkillDraft name revision validation expected -> handle name revision validation expected
