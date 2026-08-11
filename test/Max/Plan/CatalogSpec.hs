-- | The plan catalog's declarations against the tools they describe.
--
-- 'Max.Plan.Catalog' writes each plannable tool's input shape by hand, and the
-- tool itself writes the same shape again as JSON Schema for the model.  Two
-- spellings of one fact is exactly the arrangement that goes quietly wrong, so
-- the derivation nobody wanted in production lives here instead: this converts
-- the live JSON Schema and demands it agree.
--
-- Failing here means one of the two moved.  That is a build break rather than a
-- turn in which a plan type-checked against a tool that no longer takes those
-- arguments.
module Max.Plan.CatalogSpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Vector qualified as V
import Effectful (IOE)
import Effectful.Log (Log)
import Max.Effects.Tools
  ( SchemaVersion (..),
    Tool (..),
    ToolAuthority (..),
    ToolDefinition (..),
    ToolParallelism (..),
    ToolRef (..),
    ToolRetryClass (..),
  )
import Max.Plan.Catalog
import Max.Plan.Schema (PlanSchema (..), SchemaField (..))
import Max.Plan.Types (PlanEffect (..))
import Max.Plan.Validate (CatalogEntry (..))
import Max.Effects.Embedding (Embedding)
import Max.Effects.PlatformApi (PlatformApi)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import Max.ToolContext (TurnCapabilities (..), TurnIdentity (..), mkToolContext)
import Max.Tools (builtinsFor)
import Max.Tools.Memory (memoryToolsFor)
import Max.Tools.Search (SearchConfig (..), searchToolsFor)
import Effectful.PostgreSQL (WithConnection)
import OneBot.Types (GroupId (..), UserId (..))
import Data.Time (utc)
import Test.Hspec

-- | One effect row wide enough for every tool constructor this spec touches.
-- Never interpreted: only 'toolSchema' is forced, and that is a pure field.
type Row = '[Embedding, WithConnection, PlatformApi, Log, IOE]

-- | Every tool whose live JSON Schema this spec can reach without standing up
-- the world.
--
-- 'toolSchema' is a pure field; only 'toolRun' closes over the runtime, and
-- laziness means never forcing it.  Should a schema ever start depending on the
-- runtime, this crashes on the bottom rather than passing — which is the right
-- signal, because a schema that varies with the runtime cannot be declared
-- statically in 'Max.Plan.Catalog' either.
liveSchemas :: [(Text, Value)]
liveSchemas =
  [ (tool.toolName, tool.toolSchema)
    | tool <-
        searchToolsFor @Row (error "HttpRuntime forced by a tool schema") searchConfig
          <> builtinsFor @Row utc turnContext
          <> memoryToolsFor @Row turnContext
  ]
  where
    searchConfig =
      SearchConfig
        { scTavilyApiKey = "",
          scDefaultMaxResults = 5,
          scTimeoutSeconds = 10
        }
    -- Only the schema is forced, and a schema does not read the turn.  A
    -- context whose fields start mattering to one is a context this spec should
    -- stop pretending it can fabricate — it would crash rather than pass.
    turnContext =
      mkToolContext
        TurnIdentity
          { tiGroupId = GroupId 1,
            tiCanonicalId = CanonicalMessageId 1,
            tiUserId = UserId 1,
            tiSelfId = UserId 2,
            tiAuthorPrincipalId = PrincipalId 1,
            tiClearedAt = Nothing,
            tiTurnOutputContext = Nothing
          }
        TurnCapabilities
          { tcMultimodal = False,
            tcStickers = False,
            tcSkills = False,
            tcOutput = noAdvertisedCaps,
            tcMonitorArming = False,
            tcCatalogGrants = Map.empty,
            tcEffectCeiling = Nothing,
            tcSubgoal = Nothing
          }

definitionOf :: Text -> ToolDefinition
definitionOf name =
  ToolDefinition
    { tdRef = ToolRef name,
      tdSchemaVersion = SchemaVersion 1,
      tdEffects = Set.empty,
      tdParallelism = ParallelSafe,
      tdRetryClass = RetrySafe,
      tdAuthorities = Set.singleton CurrentConversation,
      tdFailuresPrecedeEffects = False
    }

spec :: Spec
spec = do
  describe "declared inputs against the schema the model is shown" $
    it "agrees wherever the live schema is reachable" $ do
      let reachable = [t | t <- plannableTools, Just _ <- [lookup t.ptRef.unToolRef liveSchemas]]
      -- A guard rather than decoration: if the reachable set went empty the
      -- comparison below would vacuously pass and the drift check would be
      -- silently doing nothing.
      map ((.unToolRef) . (.ptRef)) reachable
        `shouldBe` ["web_search", "get_message_by_id", "context_search", "memory_list"]
      sequence_
        [ (name, fromJsonSchema schema) `shouldBe` (name, Just (normalise tool.ptInput))
          | tool <- reachable,
            let name = tool.ptRef.unToolRef,
            Just schema <- [lookup name liveSchemas]
        ]

  describe "the catalog it hands the kernel" $ do
    it "keeps only tools the host actually registered" $ do
      Map.keys (planCatalog []) `shouldBe` []
      Map.keys (planCatalog [definitionOf "web_search"]) `shouldBe` [ToolRef "web_search"]

    it "ignores a registered tool nobody declared plannable" $
      -- The default, and the one that matters: every tool max gains stays
      -- unplannable until somebody reads what it returns.
      Map.keys (planCatalog [definitionOf "sandbox_exec"]) `shouldBe` []

    it "takes version and authority from the live definition, never from here" $ do
      let bumped = (definitionOf "web_search") {tdSchemaVersion = SchemaVersion 7}
          entry = Map.lookup (ToolRef "web_search") (planCatalog [bumped])
      fmap (.ceSchemaVersion) entry `shouldBe` Just (SchemaVersion 7)
      fmap (.ceAuthorities) entry `shouldBe` Just (Set.singleton CurrentConversation)

    it "declares no tool that can send or write" $
      -- Not a property of the kernel — a property of this list, and the one
      -- most worth pinning, because adding a sending tool to it is a one-line
      -- change whose consequence is that a plan can speak on its own.
      sequence_
        [ (tool.ptRef.unToolRef, filter escapes (Set.toList tool.ptEffects))
            `shouldBe` (tool.ptRef.unToolRef, [])
          | tool <- plannableTools
        ]

    it "names each tool once" $ do
      let names = map ((.unToolRef) . (.ptRef)) plannableTools
      length (Set.fromList names) `shouldBe` length names

escapes :: PlanEffect -> Bool
escapes = \case
  EffSend _ -> True
  EffWrite _ -> True
  _ -> False

-- | Sort object fields, so agreement does not depend on declaration order.
normalise :: PlanSchema -> PlanSchema
normalise = \case
  SchemaObject fields ->
    SchemaObject [f {sfSchema = normalise f.sfSchema} | f <- sortOn (.sfName) fields]
  SchemaArray inner -> SchemaArray (normalise inner)
  SchemaNullable inner -> SchemaNullable (normalise inner)
  other -> other

-- | The subset of JSON Schema max's tools actually write, read back as a
-- 'PlanSchema'.  Anything outside it is 'Nothing' rather than a lenient guess:
-- a construct this does not understand is one the declaration cannot be checked
-- against, and silently passing would defeat the test.
fromJsonSchema :: Value -> Maybe PlanSchema
fromJsonSchema (Object o) = case KeyMap.lookup "enum" o of
  Just (Array vs) -> SchemaEnum <$> traverse asText (V.toList vs)
  _ -> case KeyMap.lookup "type" o of
    Just (String "string") -> Just SchemaText
    Just (String "integer") -> Just SchemaInt
    Just (String "number") -> Just SchemaNumber
    Just (String "boolean") -> Just SchemaBool
    Just (String "array") -> SchemaArray <$> (fromJsonSchema =<< KeyMap.lookup "items" o)
    Just (String "object") -> do
      properties <- case KeyMap.lookup "properties" o of
        Just (Object properties) -> Just properties
        _ -> Nothing
      let required = case KeyMap.lookup "required" o of
            Just (Array vs) -> [t | String t <- V.toList vs]
            _ -> []
      fields <-
        traverse
          ( \(key, schema) -> do
              let name = Key.toText key
              inner <- fromJsonSchema schema
              pure SchemaField {sfName = name, sfSchema = inner, sfRequired = name `elem` required}
          )
          (KeyMap.toAscList properties)
      pure (SchemaObject (sortOn (.sfName) fields))
    _ -> Nothing
fromJsonSchema _ = Nothing

asText :: Value -> Maybe Text
asText (String t) = Just t
asText _ = Nothing
