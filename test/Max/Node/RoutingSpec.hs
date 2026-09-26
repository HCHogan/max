module Max.Node.RoutingSpec (spec) where

import Max.Monitor.Policy (OverlapPolicy (..))
import Max.Monitor.Types (MonitorFireId (..))
import Max.Node.Routing
import Test.Hspec

spec :: Spec
spec = describe "root occurrence routing" $ do
  it "queues to the exact capacity and records overflow beyond it" $
    map (routeOccurrence QueueOccurrences 2 0 . (`OccurrenceBuffer` Nothing)) [0, 1, 2, 3]
      `shouldBe` [BufferOccurrence, BufferOccurrence, RecordOverflow QueueFull, RecordOverflow QueueFull]

  it "merges only into a consumer whose input is still mutable" $ do
    let candidate = MergeCandidate (MonitorFireId 17) True 0 100
    routeOccurrence Coalesce 40 10 (OccurrenceBuffer 0 Nothing) `shouldBe` BufferOccurrence
    routeOccurrence Coalesce 40 10 (OccurrenceBuffer 1 (Just candidate)) `shouldBe` MergeInto (MonitorFireId 17)
    routeOccurrence Coalesce 40 10 (OccurrenceBuffer 1 (Just candidate {mutable = False})) `shouldBe` RecordOverflow ConsumerFrozen

  it "bounds both evidence bytes and the number of merged occurrences" $ do
    let candidate = MergeCandidate (MonitorFireId 17) True 63 131062
    routeOccurrence Coalesce 40 10 (OccurrenceBuffer 1 (Just candidate)) `shouldBe` MergeInto (MonitorFireId 17)
    routeOccurrence Coalesce 40 11 (OccurrenceBuffer 1 (Just candidate)) `shouldBe` RecordOverflow AggregateFull
    routeOccurrence Coalesce 40 0 (OccurrenceBuffer 1 (Just candidate {messages = 64})) `shouldBe` RecordOverflow AggregateFull
