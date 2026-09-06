module Max.MemoryCapabilitiesSpec (spec) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Monad (forM_, void)
import Data.Either (isRight)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (truncateAll, withDb, withDbLog)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.Task (claimFrontend)
import Max.DB.TaskSpec (seed)
import Max.DB.Transaction (withTransaction)
import Max.Effects.MemoryControl qualified as Control
import Max.Effects.MemoryQuery qualified as Query
import Max.Memory.Policy
import Max.Memory.Types
import Max.MemoryStore qualified as Store
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "scoped memory capabilities" $ do
  it "serializes tool and Historian admission at the shared capacity boundary" $ do
    (_, CanonicalMessageId message, PrincipalId principal) <- seed pool 900 1
    let conversation = conversationScopeFor (GroupId 900)
        namespace = groupMemoryNamespace conversation
        evidence = MessageEvidence conversation (Just principal) message
        tool = MemoryActor ActorAgentTool (Just principal) Nothing
        historian = MemoryActor ActorHistorian Nothing Nothing
        draft text lifecycle = MemoryDraft text lifecycle Nothing evidence
    forM_ [1 .. 29 :: Int] $ \index ->
      void $ withDb pool (Store.createMemory tool namespace (draft (T.pack (show index)) MemoryPermanent))
    outcomes <-
      mapConcurrently
        ( \index ->
            withDb pool $
              if even index
                then Store.admitMemory AllowDuplicates tool namespace (draft (T.pack (show index)) MemoryPermanent)
                else Store.admitMemory RejectExactDuplicates historian namespace (draft (T.pack (show index)) MemoryActive)
        )
        [30 .. 45 :: Int]
    length (filter isRight outcomes) `shouldBe` 1
    length [() | Left MemoryAtCapacity <- outcomes] `shouldBe` 15
    withDb pool (Store.countMemories namespace) `shouldReturn` 30
    audit <- withDb pool (query "SELECT (SELECT count(*) FROM memory_versions),(SELECT count(*) FROM memory_evidence),(SELECT count(*) FROM memory_mutations)" ())
    audit `shouldBe` [(30 :: Int64, 30 :: Int64, 30 :: Int64)]

  it "serializes exact-duplicate rejection and releases capacity on rollback" $ do
    (_, CanonicalMessageId message, PrincipalId principal) <- seed pool 900 1
    let conversation = conversationScopeFor (GroupId 900)
        namespace = groupMemoryNamespace conversation
        actor = MemoryActor ActorHistorian Nothing Nothing
        draft = MemoryDraft "same fact" MemoryActive Nothing (MessageEvidence conversation (Just principal) message)
        admit = Store.admitMemory RejectExactDuplicates actor namespace draft
    withDb pool (withTransaction (admit >> void (execute "SELECT 1/0" ()))) `shouldThrow` anyException
    withDb pool (Store.countMemories namespace) `shouldReturn` 0
    outcomes <- mapConcurrently (const (withDb pool admit)) [1 .. 8 :: Int]
    length (filter isRight outcomes) `shouldBe` 1
    length [() | Left ExactMemoryAlreadyExists <- outcomes] `shouldBe` 7

  it "binds writes to current identity, source and lease while preserving CAS and audit" $ do
    (turn, message, actor) <- seed pool 900 1
    (_, otherMessage, otherActor) <- seed pool 901 2
    withDb pool (claimFrontend turn) `shouldReturn` True
    let scope = Control.MemoryControlScope (GroupId 900) (Just turn.atrTurnId) actor message
        save = Control.saveMemory ConversationMemory "explicit fact"
        run = withDbLog pool . Control.runMemoryControl scope
    withDbLog pool (Control.runMemoryControl (scope {Control.principal = otherActor}) save) `shouldReturn` Left MemoryCallerFenced
    withDbLog pool (Control.runMemoryControl (scope {Control.group = GroupId 901}) save) `shouldReturn` Left MemoryCallerFenced
    withDbLog pool (Control.runMemoryControl (scope {Control.source = otherMessage}) save) `shouldReturn` Left MemoryCallerFenced
    run (Control.saveMemory ConversationMemory (T.replicate 301 "x")) `shouldSatisfyIO` either isInvalid (const False)
    Right item <- run save
    item.memLifecycle `shouldBe` "permanent"
    Right updated <- run (Control.updateMemory item.memId (ExpectedVersion item.memVersion) "revised fact")
    run (Control.forgetMemory item.memId (ExpectedVersion item.memVersion)) `shouldReturn` Left MemoryNotWritable
    withDb pool (Query.runMemoryQuery (conversationScopeFor (GroupId 901)) otherActor (Query.listMemories ConversationMemory)) `shouldReturn` []
    evidence <- withDb pool (query "SELECT source_principal_id,source_canonical_message_id FROM memory_evidence WHERE memory_id=? ORDER BY memory_version" (Only item.memId))
    evidence `shouldBe` replicate 2 (Just actor.unPrincipalId, Just message.unCanonicalMessageId)
    void $ withDb pool (execute "UPDATE conversation_frontends SET lease_until=now()-interval '1 second' WHERE turn_id=?" (Only turn.atrTurnId))
    run (Control.forgetMemory item.memId (ExpectedVersion updated.memVersion)) `shouldReturn` Left MemoryCallerFenced
    rows <- withDb pool (query "SELECT lifecycle,version FROM memories WHERE id=?" (Only item.memId))
    rows `shouldBe` [("permanent" :: Text, updated.memVersion)]
  where
    isInvalid (MemoryContentInvalid _) = True
    isInvalid _ = False

shouldSatisfyIO :: (Show a) => IO a -> (a -> Bool) -> Expectation
shouldSatisfyIO action predicate = action >>= (`shouldSatisfy` predicate)
