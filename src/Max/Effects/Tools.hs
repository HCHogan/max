{-# LANGUAGE TypeFamilies #-}

-- |
-- A tool registry as an 'Effect'.
--
-- 'Tools' exposes two operations: list the tool specs (for advertising
-- to the LLM), and invoke a named tool with JSON arguments.  The
-- interpreter 'runTools' takes the concrete tool list at install time.
--
-- The split between 'Tool' (in-process value) and 'ToolSpec' (wire
-- description) lets the 'Agent' loop hand specs to the LLM and
-- dispatch invocations through the effect without having tool values
-- escape.
module Max.Effects.Tools
  ( Tools,
    Tool (..),
    runTools,
    listToolSpecs,
    invokeTool,
  )
where

import Data.Aeson (Value)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Effects.LLM (ToolSpec (..))

-- | One tool the agent can call.  The runner is polymorphic in the
-- agent's effect stack, so tools naturally pull in DB / HTTP / etc.
-- as needed.
data Tool es = Tool
  { toolName :: !Text,
    toolDescription :: !Text,
    -- | JSON Schema describing the @arguments@ object the model must
    -- supply.  Pass-through to the @parameters@ field of the wire
    -- tool spec.
    toolSchema :: !Value,
    toolRun :: Value -> Eff es (Either Text Value)
  }

toToolSpec :: Tool es -> ToolSpec
toToolSpec t =
  ToolSpec
    { specName = t.toolName,
      specDescription = t.toolDescription,
      specSchema = t.toolSchema
    }

--------------------------------------------------------------------------------
-- Effect.

data Tools :: Effect where
  ListToolSpecs :: Tools m [ToolSpec]
  -- | @InvokeTool name args@.  Returns @Left@ for "tool not found" or
  -- whatever error the tool itself surfaces; @Right@ for a normal
  -- result.  Exceptions from the tool runner propagate.
  InvokeTool :: Text -> Value -> Tools m (Either Text Value)

type instance DispatchOf Tools = Dynamic

-- | Install a tool registry on top of an effect stack.  The tools'
-- runners run in the post-install stack @es@, so they have access to
-- everything below.
runTools ::
  forall es a.
  [Tool es] ->
  Eff (Tools : es) a ->
  Eff es a
runTools tools = interpret $ \_ -> \case
  ListToolSpecs -> pure (map toToolSpec tools)
  InvokeTool name args -> case Map.lookup name byName of
    Nothing -> pure (Left ("unknown tool: " <> name))
    Just t -> t.toolRun args
  where
    byName = Map.fromList [(t.toolName, t) | t <- tools]

listToolSpecs :: Tools :> es => Eff es [ToolSpec]
listToolSpecs = send ListToolSpecs

invokeTool :: Tools :> es => Text -> Value -> Eff es (Either Text Value)
invokeTool name args = send (InvokeTool name args)
