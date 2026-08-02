module Max.ToolsSpec (spec) where

import Data.Time (utc)
import Effectful (IOE)
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.PlatformApi (PlatformApi)
import Max.Effects.Tools (Tool (..))
import Max.ToolContext (ToolContext (..), TurnCapabilities (..), TurnIdentity (..))
import Max.Tools (builtinsFor)
import Max.Tools.Memory (memoryToolsFor)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

type BuiltinEffects = '[WithConnection, PlatformApi, Log, IOE]

type MemoryEffects = '[WithConnection, Log, IOE]

toolContext :: ToolContext
toolContext =
  ToolContext
    (TurnIdentity (GroupId 123) (MessageId 456) (UserId 789) (UserId 999))
    (TurnCapabilities False False False)

spec :: Spec
spec = describe "model-visible recall tools" $ do
  it "registers unified context recall without legacy message search" $ do
    let tools = builtinsFor utc Nothing toolContext :: [Tool BuiltinEffects]
    map (.toolName) tools
      `shouldBe` [ "get_message_by_id",
                   "context_search",
                   "context_expand",
                   "view_forward",
                   "poke"
                 ]

  it "does not register the legacy memory search alias" $ do
    let tools = memoryToolsFor toolContext :: [Tool MemoryEffects]
    map (.toolName) tools
      `shouldBe` ["memory_save", "memory_update", "memory_forget", "memory_list"]
