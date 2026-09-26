module Max.Context.ProjectionSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Max.Context.Projection hiding (emptyLog)
import Max.Context.Working (WorkingProjection (..))
import Max.LLM.Types (ChatMessage (..), ContentBlock (..), ToolCall (..))
import Max.ModelCatalog (ContextLimits (..))
import Max.Node.Log qualified as Log
import Test.Hspec

seeded :: (Map.Map Observer EventRef, NodeLog)
seeded = foldl add (Map.empty, Log.emptyLog) (map Observer [0, 1, 2])
  where
    add (references, nodeLog) owner =
      let (reference, next) = Log.appendTrigger owner (Log.Said Nothing) nodeLog
       in (Map.insert owner reference references, next)

emptyLog :: NodeLog
emptyLog = snd seeded

triggerFor :: Observer -> EventRef
triggerFor owner = fst seeded Map.! owner

spec :: Spec
spec = describe "observation-ordered task projection" $ do
  it "refreshes the volatile tail without saving it in a poll or compaction checkpoint" $ do
    let payload = T.replicate 20000 "汉"
        task = foldl (\record n -> addRound (T.pack (show n)) payload record) (newTaskRecord (triggerFor (Observer 0)) (logCursor emptyLog) [MsgUser "goal"]) [1 .. 6 :: Int]
    Right first <- pure (planProjection options {volatileTail = ["another task is waiting"]} emptyLog task (logCursor emptyLog))
    first.working.wpCompacted `shouldBe` True
    encode (last first.working.wpMessages) `shouldBe` encode (MsgVolatile "another task is waiting")
    let stable = project emptyLog first.record (logCursor emptyLog)
        answered = recordPoll (logCursor emptyLog) (Just (MsgAssistant "continue")) first.record
    encode stable `shouldBe` encode (init first.working.wpMessages)
    Right second <- pure (planProjection options {volatileTail = ["another task is ready"], previousSummary = first.working.wpSummary} emptyLog answered (logCursor emptyLog))
    encode second.working.wpMessages `shouldBe` encode (stable <> [MsgAssistant "continue", MsgVolatile "another task is ready"])
    [text | MsgVolatile text <- taskTranscript emptyLog second.record (logCursor emptyLog)] `shouldBe` []
    Right ended <- pure (planProjection options emptyLog second.record (logCursor emptyLog))
    encode ended.working.wpMessages `shouldBe` encode (stable <> [MsgAssistant "continue"])

  it "counts the volatile tail against the hard context budget before a request" $ do
    let task = newTaskRecord (triggerFor (Observer 0)) (logCursor emptyLog) [MsgUser "goal"]
    isLeft (planProjection options {volatileTail = [T.replicate 40000 "汉"]} emptyLog task (logCursor emptyLog)) `shouldBe` True

  it "freezes the initial window at a nonzero log cursor" $ do
    let earlierLog = appendObservation (Observer 0) [MsgUser "already in the initial window"] emptyLog
        original = [MsgSystem "rules", MsgUser "observed name and text", MsgUser "trigger"]
        task = newTaskRecord (triggerFor (Observer 0)) (logCursor earlierLog) original
        laterLog = appendObservation (Observer 0) [MsgUser "new publication"] earlierLog
    encode (project earlierLog task (logCursor earlierLog)) `shouldBe` encode original
    encode (project laterLog task (logCursor laterLog)) `shouldBe` encode (original <> [MsgUser "new publication"])
    encode (taskTranscript laterLog task (logCursor laterLog)) `shouldBe` encode [MsgUser "new publication"]

  it "places events logged during an await after every result, preserving the previous request prefix" $ do
    let initial = [MsgSystem "rules", MsgUser "search"]
        first = newTaskRecord (triggerFor (Observer 0)) (logCursor emptyLog) initial
        call = MsgAssistantToolCalls (object ["reasoning_content" .= ("opaque" :: Text)]) [ToolCall "a" "read" (object []), ToolCall "b" "read" (object [])]
        waiting = recordPoll (logCursor emptyLog) (Just call) first
        arrived = appendObservation (Observer 0) [MsgUser "stop searching"] emptyLog
        results = [MsgTool "a" "first", MsgTool "b" "second", MsgUserBlocks [TextBlock "attachment", ImageDataUrl "data:image/png;base64,AA=="]]
        completed = recordResults results waiting
        next = project arrived completed (logCursor arrived)
    encode next `shouldBe` encode (initial <> [call] <> results <> [MsgUser "stop searching"])
    encode (take (length initial) next) `shouldBe` encode (project emptyLog first (logCursor emptyLog))

  it "replays raw final reasoning before steering first observed by the next poll" $ do
    let initial = [MsgUser "request"]
        raw = object ["role" .= ("assistant" :: Text), "content" .= ("draft" :: Text), "signature" .= ("opaque signature" :: Text)]
        task = recordPoll (logCursor emptyLog) (Just (MsgAssistantRaw raw "draft")) (newTaskRecord (triggerFor (Observer 0)) (logCursor emptyLog) initial)
        arrived = appendObservation (Observer 0) [MsgUser "correction during generation"] emptyLog
        next = recordPoll (logCursor arrived) (Just (MsgAssistant "corrected")) task
        later = appendObservation (Observer 0) [MsgUser "later note"] arrived
    encode (project later next (logCursor later))
      `shouldBe` encode (initial <> [MsgAssistantRaw raw "draft", MsgUser "correction during generation", MsgAssistant "corrected", MsgUser "later note"])
    encode (project later task (logCursor emptyLog)) `shouldBe` encode (initial <> [MsgAssistantRaw raw "draft"])

  it "filters interleaved node observations by the record owner across poll boundaries" $ do
    let first = newTaskRecord (triggerFor (Observer 1)) (logCursor emptyLog) [MsgUser "first request"]
        second = newTaskRecord (triggerFor (Observer 2)) (logCursor emptyLog) [MsgUser "second request"]
        firstCut = appendObservation (Observer 1) [MsgUser "private first input"] emptyLog
        polled = recordPoll (logCursor firstCut) (Just (MsgAssistant "first answer")) first
        otherCut = appendObservation (Observer 2) [MsgUser "private second input"] firstCut
        lastCut = appendObservation (Observer 1) [MsgUser "first correction"] otherCut
    encode (project lastCut polled (logCursor lastCut))
      `shouldBe` encode [MsgUser "first request", MsgUser "private first input", MsgAssistant "first answer", MsgUser "first correction"]
    encode (project lastCut second (logCursor lastCut))
      `shouldBe` encode [MsgUser "second request", MsgUser "private second input"]

  it "keeps separate task trails while letting both observe a published event" $ do
    let first = addRound "secret-call" "private evidence" (newTaskRecord (triggerFor (Observer 1)) (logCursor emptyLog) [MsgUser "first request"])
        second = recordPoll (logCursor emptyLog) (Just (MsgAssistant "public reply")) (newTaskRecord (triggerFor (Observer 2)) (logCursor emptyLog) [MsgUser "second request"])
        published = appendObservation (Observer 2) [MsgUser "[other task published] public reply"] (appendObservation (Observer 1) [MsgUser "[other task published] public reply"] emptyLog)
    encode (project published first (logCursor published)) `shouldNotBe` encode (project published second (logCursor published))
    [cid | MsgTool cid _ <- project published second (logCursor published)] `shouldBe` []
    encode (last (project published first (logCursor published))) `shouldBe` encode (MsgUser "[other task published] public reply")

  it "retains raw evidence when compaction rewrites the cached prefix and never resurrects it on the next poll" $ do
    let payload = T.replicate 20000 "汉"
        task = foldl (\record n -> addRound (T.pack (show n)) payload record) (newTaskRecord (triggerFor (Observer 0)) (logCursor emptyLog) [MsgUser "original goal"]) [1 .. 6 :: Int]
    Right compacted <- pure (planProjection options emptyLog task (logCursor emptyLog))
    compacted.working.wpCompacted `shouldBe` True
    let waiting = recordPoll (logCursor emptyLog) (Just (MsgAssistant "next action")) compacted.record
        arrived = appendObservation (Observer 0) [MsgUser "do not deploy"] emptyLog
        next = project arrived waiting (logCursor arrived)
    encode next `shouldBe` encode (compacted.working.wpMessages <> [MsgAssistant "next action", MsgUser "do not deploy"])
    [body | MsgTool _ body <- taskTranscript arrived waiting (logCursor arrived)] `shouldBe` replicate 6 payload
    compacted.working.wpSummary `shouldSatisfy` T.isInfixOf "context_resume(turn=t#7"
    Right stable <- pure (planProjection options {previousSummary = compacted.working.wpSummary} arrived waiting (logCursor arrived))
    stable.working.wpCompacted `shouldBe` False
    encode stable.working.wpMessages `shouldBe` encode next

  it "keeps media eviction in the projection while retaining the original tool evidence" $ do
    let oldImage = MsgUserBlocks [TextBlock "old", ImageDataUrl "data:image/png;base64,AA=="]
        newImage = MsgUserBlocks [TextBlock "new", ImageDataUrl "data:image/png;base64,AQ=="]
        task = recordResults [MsgTool "image" "attached", oldImage] (recordPoll (logCursor emptyLog) (Just (MsgAssistantToolCalls (object []) [ToolCall "image" "view_image" (object [])])) (newTaskRecord (triggerFor (Observer 0)) (logCursor emptyLog) [MsgUser "inspect"]))
    Right evicted <- pure (planProjection options {removeMedia = True} emptyLog task (logCursor emptyLog))
    evicted.hasMedia `shouldBe` False
    evicted.evictedMedia `shouldBe` 1
    let continued = recordResults [MsgTool "image" "attached", newImage] (recordPoll (logCursor emptyLog) (Just (MsgAssistantToolCalls (object []) [ToolCall "image" "view_image" (object [])])) evicted.record)
        projected = project emptyLog continued (logCursor emptyLog)
    [url | MsgUserBlocks blocks <- projected, ImageDataUrl url <- blocks] `shouldBe` ["data:image/png;base64,AQ=="]
    [url | MsgUserBlocks blocks <- taskTranscript emptyLog continued (logCursor emptyLog), ImageDataUrl url <- blocks] `shouldBe` ["data:image/png;base64,AA==", "data:image/png;base64,AQ=="]

  it "restores guest-loaded skills once without moving later observations ahead of a previous answer" $ do
    let task = newTaskRecord (triggerFor (Observer 0)) (logCursor emptyLog) [MsgSystem "rules", MsgUser "request"]
    Right first <- pure (planProjection options {skillInstructions = ["skill instructions"]} emptyLog task (logCursor emptyLog))
    let answered = recordPoll (logCursor emptyLog) (Just (MsgAssistant "draft")) first.record
        arrived = appendObservation (Observer 0) [MsgUser "correction"] emptyLog
    Right second <- pure (planProjection options {skillInstructions = ["skill instructions"]} arrived answered (logCursor arrived))
    encode second.working.wpMessages `shouldBe` encode (first.working.wpMessages <> [MsgAssistant "draft", MsgUser "correction"])

options :: ProjectionOptions
options = ProjectionOptions (ContextLimits 12000 4000 2048 1000 Nothing Nothing) Nothing "id" "t#7" "" [] [] False []

addRound :: Text -> Text -> TaskRecord -> TaskRecord
addRound ident body = recordResults [MsgTool ident body] . recordPoll (logCursor emptyLog) (Just (MsgAssistantToolCalls (object []) [ToolCall ident "read" (object [])]))
