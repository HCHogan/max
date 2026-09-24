module Max.ToolsSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Aeson.Types (parseEither)
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (minutesToTimeZone, utc)
import Effectful.Log (Log)
import Max.Context.Capacity
import Max.Context.Read
import Max.Effects.ConversationQuery (ConversationQuery)
import Max.Effects.Embedding (Embedding)
import Max.Effects.MemoryControl (MemoryControl)
import Max.Effects.MemoryQuery (MemoryQuery)
import Max.Effects.PlatformInteraction (PlatformInteraction)
import Max.Effects.Tools (Tool (..))
import Max.Effects.TurnQuery (TurnQuery)
import Max.ModelCatalog (ContextLimits (..), defaultContextLimits)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), qqAdvertisedCaps)
import Max.Time.Parse (parseTimeArg)
import Max.ToolContext (ToolContext, TurnCapabilities (..), TurnIdentity (..), mkToolContext)
import Max.Tools (builtinsFor)
import Max.Tools.Memory (memoryToolsFor)
import OneBot.Types (GroupId (..), UserId (..))
import Test.Hspec

type BuiltinEffects = '[ConversationQuery, TurnQuery, PlatformInteraction, Embedding, Log]

type MemoryEffects = '[MemoryQuery, MemoryControl]

toolContext :: ToolContext
toolContext =
  mkToolContext
    (TurnIdentity (GroupId 123) (CanonicalMessageId 456) (UserId 789) (UserId 999) (PrincipalId 789) Nothing Nothing)
    ( TurnCapabilities
        { tcMultimodal = False,
          tcStickers = False,
          tcSkills = False,
          tcOutput = qqAdvertisedCaps,
          tcMonitorArming = True,
          tcCatalogGrants = Map.empty,
          tcEffectCeiling = Nothing,
          tcBackground = False
        }
    )

spec :: Spec
spec = describe "model-visible builtins" $ do
  it "registers source inspection and unified recall without legacy search" $ do
    let tools = builtinsFor utc toolContext :: [Tool BuiltinEffects]
    map (.toolName) tools
      `shouldBe` [ "inspect_source",
                   "context_search",
                   "context_read",
                   "context_resume",
                   "poke"
                 ]

  it "does not register the legacy memory search alias" $ do
    let tools = memoryToolsFor :: [Tool MemoryEffects]
    map (.toolName) tools
      `shouldBe` ["memory_save", "memory_update", "memory_forget", "memory_list"]

  it "keeps canonical IDs lossless and validates selectors" $ do
    parseReadRef "message:9007199254740993" `shouldBe` Right (MessageRef 9007199254740993)
    parseReadRef "message:9223372036854775808" `shouldSatisfy` isLeft
    parseEither (parseReadRequest utc) (object ["ref" .= ("message:1" :: T.Text), "before" .= (-1 :: Int)]) `shouldSatisfy` isLeft
    parseEither (parseReadRequest utc) (object ["cursor" .= ("anything" :: T.Text), "limit" .= (2 :: Int)]) `shouldSatisfy` isLeft
    parseEither (parseReadRequest utc) (object ["from" .= ("2026-09-24" :: T.Text), "until" .= ("2026-09-23" :: T.Text)]) `shouldSatisfy` isLeft

  it "roundtrips opaque scope-bound cursors and rejects a foreign conversation" $ do
    let cursor = ReadCursor 1 123 Timeline Nothing Nothing Nothing True 9007199254740993 40
    decodeReadCursor 123 (encodeReadCursor cursor) `shouldBe` Right cursor
    decodeReadCursor 124 (encodeReadCursor cursor) `shouldSatisfy` isLeft
    decodeReadCursor 123 "not-base64" `shouldSatisfy` isLeft

  it "honors explicit ISO offsets and Z rather than applying the configured zone twice" $ do
    let local = minutesToTimeZone 600
    parseTimeArg local "2026-09-24T10:30:00+10:00" `shouldBe` parseTimeArg utc "2026-09-24T00:30:00Z"
    parseTimeArg local "2026-09-24 10:30" `shouldBe` parseTimeArg utc "2026-09-24 00:30"
    parseTimeArg local "2026-09-24T00:30:00Z" `shouldBe` parseTimeArg utc "2026-09-24 00:30"

  it "derives history, episode and page capacities from input limits" $ do
    let small = defaultContextLimits {maxInputTokens = 65536, toolRoundReserve = 8192, attachmentReserve = 8192}
        big = small {maxInputTokens = 262144}
    rawHighTokens big False `shouldBe` 126976
    rawLowTokens big False * 2 `shouldBe` rawHighTokens big False
    summaryTokens big False `shouldSatisfy` (> summaryTokens small False)
    readPageTokens big False `shouldSatisfy` (> readPageTokens small False)
    rawHighTokens big True `shouldBe` rawHighTokens big False - 4096
    -- max_input is already an input ceiling, so output is not subtracted twice.
    rawHighTokens (big {reservedOutputTokens = 60000}) False `shouldBe` rawHighTokens big False

  it "splits long Unicode bodies without losing codepoints" $ do
    let body = T.replicate 1000 "聊天😀"
        first = takeTextTokens 200 body
    T.null first `shouldBe` False
    T.length first `shouldSatisfy` (< T.length body)
    first <> T.drop (T.length first) body `shouldBe` body
    takeTextTokens 1 "😀" `shouldBe` "😀"
