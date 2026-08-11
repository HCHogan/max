-- | The whole of what a fork child is told.
--
-- ADR 002's isolation rule, rendered. A child sees its 'Goal', the values it
-- asked for by name, and the conversation it lives in — and nothing about the
-- plan that forked it: not its siblings, not the objective above it, not what
-- will be done with its answer. Anything more would make the fan-out an
-- accumulation of context, which is the thing it exists to avoid.
--
-- Pure, and separate from the dispatcher that sends it, because this is the
-- artifact under test as much as the kernel is: what a real model does with a
-- subgoal is a question about these words, and answering it should not require
-- standing up a bot.
module Max.Plan.Brief
  ( subgoalBrief,
    renderPlanValue,
  )
where

import Data.Aeson (Value (..), encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Plan.Drive (Dispatchable (..))
import Max.Plan.Reconcile (Desired (..))
import Max.Plan.Schema (renderSchema)
import Max.Plan.Types (Binder (..), EffectBudget (..), Goal (..))

-- | What one child opens with.
subgoalBrief ::
  -- | The plan's conversation-scoped ordinal, for the header.
  Int ->
  Dispatchable ->
  Text
subgoalBrief ordinal item =
  T.intercalate
    "\n"
    ( [ "[子任务 — 计划 #" <> tshow ordinal <> "]",
        "要做的事：" <> T.take 4000 goal.goalObjective,
        "要交回的结果类型：" <> renderSchema goal.goalExpected,
        "额度：最多 " <> tshow goal.goalBudget.ebMaxCalls <> " 次工具调用。"
      ]
        -- The inputs block: exactly the names the subgoal asked for, resolved
        -- to what they actually are.  This is the only thing a child knows
        -- about the plan above it, and it knows it because it said it needed
        -- it.  Absent entirely when it asked for nothing, rather than an empty
        -- heading that reads like something went missing.
        <> ( if null item.dpInputs
               then []
               else
                 ["", "上面算好交给你的东西："]
                   <> [ "  " <> binder.unBinder <> " = " <> T.take 4000 (renderPlanValue value)
                      | (binder, value) <- item.dpInputs
                      ]
           )
        <> [ "",
             "这一轮是别人派给你的一小块活，你看不到上面在做什么，也不需要看到。",
             "做完用 subgoal_return 把结果交回去——那是唯一会被读到的东西，你说的话没有人看得见。",
             "做不出来也交：交一个说明情况的值，比什么都不交强。",
             -- Measured, not guessed: two of nine live children answered a
             -- Chinese objective in English.  The value goes straight into a
             -- plan whose result a group reads, so the language it comes back
             -- in is part of the answer's shape and had to be said.
             "结果用「要做的事」那句话所用的语言写。"
           ]
    )
  where
    goal = item.dpDesired.dsGoal

-- | A plan value as one line of prose.
--
-- Text passes through unquoted, because a child reading @框架 = "effectful"@
-- with the quotes is being shown an encoding rather than a value; everything
-- else is JSON, which is what it already is.
renderPlanValue :: Value -> Text
renderPlanValue = \case
  String text -> text
  other -> TE.decodeUtf8Lenient (LBS.toStrict (encode other))

tshow :: Show a => a -> Text
tshow = T.pack . show
