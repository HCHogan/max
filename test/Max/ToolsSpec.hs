module Max.ToolsSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Time (utc)
import Effectful (IOE)
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Max.Effects.Embedding (Embedding)
import Max.Effects.PlatformApi (PlatformApi)
import Max.Effects.Tools (Tool (..))
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), qqAdvertisedCaps)
import Max.ToolContext (ToolContext, TurnCapabilities (..), TurnIdentity (..), mkToolContext)
import Max.Tools (builtinsFor)
import Max.Tools.Memory (memoryToolsFor)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

type BuiltinEffects = '[WithConnection, PlatformApi, Embedding, Log, IOE]

type MemoryEffects = '[WithConnection, Log, IOE]

toolContext :: ToolContext
toolContext =
  mkToolContext
    (TurnIdentity (GroupId 123) (CanonicalMessageId 456) (UserId 789) (UserId 999) (PrincipalId 789) Nothing Nothing)
    (TurnCapabilities False False False qqAdvertisedCaps True Map.empty Nothing Nothing)

spec :: Spec
spec = describe "model-visible builtins" $ do
  it "registers source inspection and unified recall without legacy search" $ do
    let tools = builtinsFor utc toolContext :: [Tool BuiltinEffects]
    map (.toolName) tools
      `shouldBe` [ "inspect_source",
                   "get_message_by_id",
                   "context_search",
                   "context_expand",
                   "view_forward",
                   "poke"
                 ]

  it "does not register the legacy memory search alias" $ do
    let tools = memoryToolsFor toolContext :: [Tool MemoryEffects]
    map (.toolName) tools
      `shouldBe` ["memory_save", "memory_update", "memory_forget", "memory_list"]
