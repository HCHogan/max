module Max.Node.RoutingSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import Max.Monitor.Policy (OverlapPolicy (..))
import Max.Monitor.Types (MonitorFireId (..))
import Max.Node.Routing
import Max.Platform.Types (PrincipalId (..))
import Max.Task.FrontendInput (FrontendInputView (..))
import Test.Hspec

spec :: Spec
spec = describe "node routing policy" $ do
  let note = FrontendInputView 100 "steering" 7 Nothing (UTCTime (fromGregorian 2026 9 26) 0) Nothing "correction"
      incoming :: FrontendInput Int
      incoming = FrontendInput (PrincipalId 7) (Just 100) Nothing (Just note)
      owner :: Int -> FrontendOwner Int
      owner n = FrontendOwner n (fromIntegral n) (PrincipalId 7) (Just (fromIntegral n)) (Just (fromIntegral n)) True True
  it "routes unquoted steering to the newest started open owner of the same principal" $ do
    let peers = [owner 1, (owner 5) {started = False}, (owner 4) {open = False}, (owner 3) {principal = PrincipalId 8}, owner 2]
    route (Frontend incoming peers) `shouldBe` Just 2
    route (Frontend incoming {feedback = Nothing} peers) `shouldBe` Nothing
    route (Frontend incoming {feedback = Just note {kind = "reply"}} peers) `shouldBe` Nothing

  it "targets quoted triggers and published outputs before an owner's first segment" $ do
    let quoted = incoming {sender = PrincipalId 8, feedback = Just note {replyTo = Just 1}}
        peers = [(owner 1) {started = False}, owner 2]
    route (Frontend quoted peers) `shouldBe` Just 1
    route (Frontend quoted {replyOwner = Just 2} peers) `shouldBe` Just 2
    route (Frontend quoted {replyOwner = Just 99} peers) `shouldBe` Nothing
    route (Frontend quoted {feedback = Just note {replyTo = Just 99}} peers) `shouldBe` Nothing

  it "never routes stale or unproven input, or redirects a closed quoted target" $ do
    route (Frontend incoming {ingestOrder = Nothing} [owner 1]) `shouldBe` Nothing
    route (Frontend incoming {ingestOrder = Just 1} [owner 1]) `shouldBe` Nothing
    route (Frontend incoming {feedback = Just note {replyTo = Just 1}} [(owner 1) {open = False}, owner 2]) `shouldBe` Nothing

  it "buffers owned completions while open and relays after closure, folding only normal tells" $ do
    map (\kind -> route (Delivery kind True)) [Completion, Message True (), Message False ()]
      `shouldBe` replicate 3 BufferDelivery
    map (\kind -> route (Delivery kind False)) [Completion, Message True (), Message False ()]
      `shouldBe` [RelayDelivery, RelayDelivery, FoldDelivery ()]

  it "queues to the exact capacity and records overflow beyond it" $
    map (route . Occurrence QueueOccurrences 2 0 . (`OccurrenceBuffer` Nothing)) [0, 1, 2, 3]
      `shouldBe` [BufferOccurrence, BufferOccurrence, RecordOverflow QueueFull, RecordOverflow QueueFull]

  it "merges only into a consumer whose input is still mutable" $ do
    let candidate = MergeCandidate (MonitorFireId 17) True 0 100
    route (Occurrence Coalesce 40 10 (OccurrenceBuffer 0 Nothing)) `shouldBe` BufferOccurrence
    route (Occurrence Coalesce 40 10 (OccurrenceBuffer 1 (Just candidate))) `shouldBe` MergeInto (MonitorFireId 17)
    route (Occurrence Coalesce 40 10 (OccurrenceBuffer 1 (Just candidate {mutable = False}))) `shouldBe` RecordOverflow ConsumerFrozen

  it "bounds both evidence bytes and the number of merged occurrences" $ do
    let candidate = MergeCandidate (MonitorFireId 17) True 63 131062
    route (Occurrence Coalesce 40 10 (OccurrenceBuffer 1 (Just candidate))) `shouldBe` MergeInto (MonitorFireId 17)
    route (Occurrence Coalesce 40 11 (OccurrenceBuffer 1 (Just candidate))) `shouldBe` RecordOverflow AggregateFull
    route (Occurrence Coalesce 40 0 (OccurrenceBuffer 1 (Just candidate {messages = 64}))) `shouldBe` RecordOverflow AggregateFull
