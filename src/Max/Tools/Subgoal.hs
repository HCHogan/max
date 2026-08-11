-- | How a fork child hands its answer back.
--
-- ADR 007 §11. A child turn exists to produce a /value/ for one subgoal, and
-- that is the whole difference between delegating work and starting a
-- conversation about it: whatever a child says in prose goes nowhere, because
-- the plan that forked it binds a name to a typed result and every expression
-- after the fork was validated against that type.
--
-- So there is exactly one way for a child to succeed, and this is it.
--
--   * __The argument schema is the subgoal's own declared result type.__  Not
--     a re-description of it — 'Max.Plan.Schema.jsonSchemaOf' renders the very
--     'Max.Plan.Types.goalExpected' the parent plan was checked against, so
--     the shape the child is asked for cannot drift from the shape the plan
--     will read.
--   * __It is checked again on the way in.__  A model can write JSON that its
--     schema does not describe, and a value that fails here is refused with
--     the mismatch rather than stored for the plan to trip over — which is the
--     same rule "Max.Plan.Execute" applies to a tool result, for the same
--     reason.
--   * __It writes to the spawn edge, not to the plan.__  The child does not
--     move the plan's head, does not wake it, and does not know it exists.
--     Waking happens because the child's /turn/ settles, which is a fact the
--     database publishes on its own.
module Max.Tools.Subgoal
  ( subgoalToolsFor,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Plan (recordChildResult)
import Max.Effects.Tools (Tool (..))
import Max.Plan.Schema (checkValue, jsonSchemaOf, renderSchema, schemaErrorText)
import Max.ToolContext (SubgoalReturn (..), ToolContext, toolSubgoal)

-- | The one tool a fork child has that an ordinary turn does not, and only
-- when this turn actually is one.
subgoalToolsFor :: (WithConnection :> es, IOE :> es) => ToolContext -> [Tool es]
subgoalToolsFor dc = case toolSubgoal dc of
  Nothing -> []
  Just subgoal -> [returnTool subgoal]

returnTool :: (WithConnection :> es, IOE :> es) => SubgoalReturn -> Tool es
returnTool subgoal =
  Tool
    { toolName = "subgoal_return",
      toolDescription =
        T.unwords
          [ "把这个子任务的结果交回去。你这一轮说的话没有人看得见，只有这里交的值会回到上层计划里。",
            "结果类型必须是：" <> renderSchema subgoal.sgExpected <> "。",
            "查完就交，别等到最后一句话。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties" .= Object (KeyMap.fromList [(Key.fromText "result", jsonSchemaOf subgoal.sgExpected)]),
            "required" .= (["result"] :: [Text]),
            "additionalProperties" .= False
          ],
      toolRun = \args -> case KeyMap.lookup "result" =<< asObject args of
        Nothing -> pure (Left "少了 result 这个参数")
        Just result -> case checkValue subgoal.sgExpected result of
          -- Refused rather than stored.  A value the plan cannot read is not a
          -- partial success, and the model is the one who can fix it — it is
          -- still holding everything it learned.
          Left mismatch ->
            pure (Left ("结果对不上要求的类型：" <> schemaErrorText mismatch))
          Right () -> do
            written <- recordChildResult subgoal.sgTurn result
            pure $
              if written
                then Right (object ["returned" .= True, "note" .= ("交回去了，这一轮可以结束了。" :: Text)])
                else -- Not a child turn after all: the spawn edge is gone, or
                -- this context was minted for a turn nobody forked. Reported
                -- rather than silently accepted, because the difference is
                -- whether anybody is ever going to read the value.
                  Left "这一轮不是某个计划的子任务，没有地方可以交"
    }
  where
    asObject = \case
      Object o -> Just o
      _ -> Nothing

