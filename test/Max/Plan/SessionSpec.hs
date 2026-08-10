module Max.Plan.SessionSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Max.Effects.Tools (SchemaVersion (..), ToolRef (..))
import Max.Plan.Schema (PlanSchema (..), SchemaField (..))
import Max.Plan.Session
import Max.Plan.Types
import Max.Plan.Validate
import Test.Hspec

field :: Text -> PlanSchema -> SchemaField
field name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = True}

searchTool :: CatalogEntry
searchTool =
  CatalogEntry
    { ceRef = ToolRef "search_web",
      ceSchemaVersion = SchemaVersion 3,
      ceInput = SchemaObject [field "query" SchemaText],
      ceResult = SchemaArray (SchemaObject [field "title" SchemaText]),
      ceEffects = Set.singleton (EffRead (ExternalScope "web")),
      ceAuthorities = Set.empty
    }

handle :: Text -> (Text, ValueRef)
handle name =
  ( name,
    ValueRef
      { vrHandle = name,
        vrSchema = SchemaText,
        vrScope = CurrentConversation,
        vrDigest = "abc",
        vrLength = 10,
        vrRetained = True
      }
  )

env :: ValidationEnv
env =
  ValidationEnv
    { venCatalog = Map.singleton searchTool.ceRef searchTool,
      venVerifiers = Map.empty,
      venHandles = Map.fromList [handle "t#1:r1", handle "t#1:r2"],
      venAdmittedVerifiers = Set.empty,
      venGoal =
        Goal
          { goalObjective = "回答",
            goalExpected = SchemaText,
            goalAcceptance = [],
            goalBudget =
              EffectBudget
                { ebEffects = Set.singleton (EffRead (ExternalScope "web")),
                  ebMaxCalls = 2,
                  ebMaxSends = 0,
                  ebMaxFanout = 8,
                  ebMaxTokens = 8000,
                  ebMaxWallClockMs = 30000
                },
            goalAuthority = Set.empty,
            goalResources = [],
            goalInputs = [],
            goalDeps = noDependencies,
            goalEvidence = [],
            goalAttempt = 0
          },
      venBindings = Map.empty,
      venCostCeiling = 100000
    }

grant :: Text -> PullGrant
grant fingerprint =
  PullGrant
    { pgBody = "body",
      pgFingerprint = fingerprint,
      pgBytes = 100,
      pgTokens = 50,
      pgElapsedMs = 10
    }

session0 :: Session
session0 = newSession defaultSessionFuel

spec :: Spec
spec = do
  describe "pulling evidence" $ do
    it "grants a handle the host already resolved, and records what it read" $
      case pull env session0 (PullResult "t#1:r1") (grant "sha-1") of
        Right session -> do
          sessionRoundsUsed session `shouldBe` 1
          (sessionReadSet session).unDependencySet
            `shouldBe` Map.singleton (DepResult "t#1:r1") "sha-1"
        Left denial -> expectationFailure ("unexpectedly denied: " <> show denial)

    it "denies a handle the environment never resolved" $
      pull env session0 (PullResult "t#9:r9") (grant "sha")
        `shouldBe` Left (NotAddressable "t#9:r9")

    it "addresses a turn record through a result of that turn" $ do
      pull env session0 (PullTurnRecord "t#1") (grant "sha") `shouldSatisfy` isRight'
      pull env session0 (PullTurnRecord "t#4") (grant "sha")
        `shouldBe` Left (NotAddressable "t#4")

    it "accumulates the read-set across rounds" $ do
      let steps =
            pull env session0 (PullResult "t#1:r1") (grant "sha-1")
              >>= \one -> pull env one (PullResult "t#1:r2") (grant "sha-2")
      fmap (Map.keys . (.unDependencySet) . sessionReadSet) steps
        `shouldBe` Right [DepResult "t#1:r1", DepResult "t#1:r2"]

  describe "fuel" $ do
    it "exhausts each dimension on its own" $ do
      -- Each ceiling is tightened alone, so none of these can pass by way of
      -- another dimension running out first.
      pull env (newSession defaultSessionFuel {sfRounds = 0}) (PullResult "t#1:r1") (grant "s")
        `shouldBe` Left (Exhausted OutOfRounds)
      -- bytes
      pull env (newSession defaultSessionFuel {sfBytes = 10}) (PullResult "t#1:r1") (grant "s")
        `shouldBe` Left (Exhausted OutOfBytes)
      -- tokens
      pull env (newSession defaultSessionFuel {sfTokens = 10}) (PullResult "t#1:r1") (grant "s")
        `shouldBe` Left (Exhausted OutOfTokens)
      -- wall clock
      pull env (newSession defaultSessionFuel {sfWallClockMs = 5}) (PullResult "t#1:r1") (grant "s")
        `shouldBe` Left (Exhausted OutOfTime)

    it "denies rather than truncating, so the model never reads half a document" $ do
      let session = newSession defaultSessionFuel {sfBytes = 150}
      case pull env session (PullResult "t#1:r1") (grant "s") of
        Right one ->
          -- The first fits; the second would go over and is refused whole.
          pull env one (PullResult "t#1:r2") (grant "s")
            `shouldBe` Left (Exhausted OutOfBytes)
        Left denial -> expectationFailure ("first pull denied: " <> show denial)

    it "spends nothing on a denied pull" $ do
      let session = newSession defaultSessionFuel {sfRounds = 1}
      case pull env session (PullResult "t#1:r1") (grant "s") of
        Right one -> do
          pull env one (PullResult "t#1:r2") (grant "s") `shouldSatisfy` isLeft'
          sessionRoundsUsed one `shouldBe` 1
        Left denial -> expectationFailure ("first pull denied: " <> show denial)

  describe "submitting a candidate" $ do
    let source = "let hits = search_web@3({ query: \"q\" })\ndone hits[0].title ?? \"\""

    it "admits a well-formed candidate and reports the read-set" $ do
      let session = either (error . show) id (pull env session0 (PullResult "t#1:r1") (grant "sha-1"))
      case submit env "turn:1:0" session source of
        Admitted _ deps ->
          deps.unDependencySet `shouldBe` Map.singleton (DepResult "t#1:r1") "sha-1"
        other -> expectationFailure ("expected admission, got " <> show other)

    it "reports a malformed surface as an ordinary elaboration failure" $
      case submit env "turn:1:0" session0 "let x = " of
        Unparsed _ -> pure ()
        other -> expectationFailure ("expected a parse failure, got " <> show other)

    it "reports a kernel refusal separately from a parse failure" $
      case submit env "turn:1:0" session0 "done nope" of
        Refused _ -> pure ()
        other -> expectationFailure ("expected a refusal, got " <> show other)

    it "attaches the read-set to the holes the candidate leaves behind" $ do
      let session = either (error . show) id (pull env session0 (PullResult "t#1:r1") (grant "sha-1"))
          withHole =
            "let hits = search_web@3({ query: \"q\" })\n\
            \hole \"接着做什么\" : text budget { calls: 1, fanout: 8, tokens: 10, ms: 10 } effects { read(external \"web\") }"
      case submit env "turn:1:0" session withHole of
        Admitted valid _ ->
          map (\(_, goal) -> goal.goalDeps.unDependencySet) (planHoles "turn:1:0" (validPlan valid))
            `shouldBe` [Map.singleton (DepResult "t#1:r1") "sha-1"]
        other -> expectationFailure ("expected admission, got " <> show other)

  describe "revalidation before execution" $ do
    let observed = observeDependency (DepResult "t#1:r1") "sha-1" noDependencies

    it "passes when nothing moved" $
      stillFresh (Map.singleton (DepResult "t#1:r1") "sha-1") observed `shouldBe` Right ()

    it "catches a dependency whose fingerprint moved" $
      stillFresh (Map.singleton (DepResult "t#1:r1") "sha-2") observed
        `shouldBe` Left Staleness {stKey = DepResult "t#1:r1", stReadAs = "sha-1", stNow = Just "sha-2"}

    it "treats a vanished dependency as changed, not as absent" $
      stillFresh Map.empty observed
        `shouldBe` Left Staleness {stKey = DepResult "t#1:r1", stReadAs = "sha-1", stNow = Nothing}

    it "is vacuously fresh when nothing was read" $
      stillFresh Map.empty noDependencies `shouldBe` Right ()

isRight' :: Either a b -> Bool
isRight' = either (const False) (const True)

isLeft' :: Either a b -> Bool
isLeft' = either (const True) (const False)
