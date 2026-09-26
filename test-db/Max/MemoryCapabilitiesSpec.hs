module Max.MemoryCapabilitiesSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (mapConcurrently, wait, withAsync)
import Control.Monad (forM_, void)
import Data.Either (isRight)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful (liftIO, raise)
import Effectful.PostgreSQL (execute, query)
import Helpers (truncateAll, withDb, withDbLog)
import JobFixture (seed)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.AgentTurn (AgentTurnTerminal (..), finishAgentTurn)
import Max.DB.Connection (DbPool)
import Max.DB.ConversationLock (lockTurnConversation)
import Max.DB.Transaction (withTransaction)
import Max.Effects.MemoryControl qualified as Control
import Max.Effects.MemoryQuery qualified as Query
import Max.Execution.Authority (newCallAuthority, revokeCallAuthority)
import Max.Memory.Policy
import Max.Memory.Types
import Max.MemoryStore qualified as Store
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..))
import Max.Turn.Types (AgentTurnRef (..))
import OneBot.Types (GroupId (..))
import System.Timeout (timeout)
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
    withDb pool (withTransaction (raise admit >> void (execute "SELECT 1/0" ()))) `shouldThrow` anyException
    withDb pool (Store.countMemories namespace) `shouldReturn` 0
    outcomes <- mapConcurrently (const (withDb pool admit)) [1 .. 8 :: Int]
    length (filter isRight outcomes) `shouldBe` 1
    length [() | Left ExactMemoryAlreadyExists <- outcomes] `shouldBe` 7

  it "binds writes to current identity, source and turn lifetime while preserving CAS and audit" $ do
    (turn, message, actor) <- seed pool 900 1
    (_, otherMessage, otherActor) <- seed pool 901 2
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
    withDb pool (finishAgentTurn turn TurnCancelled 0 (Just "cancelled"))
    run (Control.forgetMemory item.memId (ExpectedVersion updated.memVersion)) `shouldReturn` Left MemoryCallerFenced
    rows <- withDb pool (query "SELECT lifecycle,version FROM memories WHERE id=?" (Only item.memId))
    rows `shouldBe` [("permanent" :: Text, updated.memVersion)]

  it "keeps identity and provenance fences for a call that survives a successful turn" $ do
    (turn, message, actor) <- seed pool 900 1
    (otherTurn, otherMessage, otherActor) <- seed pool 901 2
    authority <- newCallAuthority turn.atrTurnId "memory_save" (pure True)
    let scope = Control.MemoryControlScope (GroupId 900) (Just turn.atrTurnId) actor message
        save = Control.saveMemory ConversationMemory "admitted write"
        run bound = withDbLog pool . Control.runMemoryControlWithAuthority (Just authority) bound
    withDb pool (finishAgentTurn turn TurnSucceeded 1 Nothing)
    withDbLog pool (Control.runMemoryControl scope save) `shouldReturn` Left MemoryCallerFenced
    forM_ [scope {Control.group = GroupId 901}, scope {Control.principal = otherActor}, scope {Control.source = otherMessage}, scope {Control.turn = Just otherTurn.atrTurnId}] $ \foreignScope ->
      run foreignScope save `shouldReturn` Left MemoryCallerFenced
    run scope save `shouldSatisfyIO` isRight
    revokeCallAuthority authority
    run scope save `shouldReturn` Left MemoryCallerFenced
    withDb pool (query "SELECT count(*) FROM memory_mutations" ()) `shouldReturn` [Only (1 :: Int)]

  it "does not let call authority override cancellation or a crash" $ do
    forM_ [TurnCancelled, TurnCrashed] $ \terminal -> do
      (turn, message, actor) <- seed pool 900 1
      authority <- newCallAuthority turn.atrTurnId "memory_save" (pure True)
      withDb pool (finishAgentTurn turn terminal 0 Nothing)
      let scope = Control.MemoryControlScope (GroupId 900) (Just turn.atrTurnId) actor message
      withDbLog pool (Control.runMemoryControlWithAuthority (Just authority) scope (Control.saveMemory ConversationMemory "forbidden")) `shouldReturn` Left MemoryCallerFenced
    withDb pool (query "SELECT count(*) FROM memories" ()) `shouldReturn` [Only (0 :: Int)]

  it "rechecks call revocation after waiting for the conversation commit lock" $ do
    (turn, message, actor) <- seed pool 900 1
    authority <- newCallAuthority turn.atrTurnId "memory_save" (pure True)
    locked <- newEmptyMVar
    release <- newEmptyMVar
    writerPid <- newEmptyMVar
    let scope = Control.MemoryControlScope (GroupId 900) (Just turn.atrTurnId) actor message
        holdLock = withDb pool . withTransaction $ do
          _ <- lockTurnConversation turn.atrTurnId
          liftIO (putMVar locked () >> takeMVar release)
        write = withDbLog pool . withTransaction $ do
          rows <- query "SELECT pg_backend_pid()" ()
          case rows of
            [Only pid] -> liftIO (putMVar writerPid (pid :: Int))
            _ -> liftIO (fail "missing PostgreSQL backend identity")
          raise (Control.runMemoryControlWithAuthority (Just authority) scope (Control.saveMemory ConversationMemory "revoked while blocked"))
        awaitBlocked pid = do
          rows <- withDb pool (query "SELECT cardinality(pg_blocking_pids(?)) > 0" (Only pid))
          if rows == [Only True] then pure () else threadDelay 1000 >> awaitBlocked pid
    withAsync holdLock $ \holder -> do
      takeMVar locked
      withAsync write $ \writer -> do
        pid <- takeMVar writerPid
        timeout 3000000 (awaitBlocked pid) `shouldReturn` Just ()
        revokeCallAuthority authority
        putMVar release ()
        timeout 3000000 (wait writer) `shouldReturn` Just (Left MemoryCallerFenced)
      wait holder
    withDb pool (query "SELECT count(*) FROM memory_mutations" ()) `shouldReturn` [Only (0 :: Int)]

  it "admits only canonical principals visible in the current conversation" $ do
    (turn, message, actor) <- seed pool 900 2783846439
    (_, _, colleague) <- seed pool 900 3526452465
    (_, _, stranger) <- seed pool 901 777777777
    let scope = Control.MemoryControlScope (GroupId 900) (Just turn.atrTurnId) actor message
        save subject = withDbLog pool (Control.runMemoryControl scope (Control.saveMemory subject "explicit personal fact"))
        rejected = Left (MemoryAdmissionRejected MemorySubjectNotVisible)
    save (PersonMemory (Just 2783846439)) `shouldReturn` rejected
    save (PersonMemory (Just 999999999)) `shouldReturn` rejected
    save (PersonMemory (Just stranger.unPrincipalId)) `shouldReturn` rejected
    save (PersonMemory Nothing) `shouldSatisfyIO` isRight
    save (PersonMemory (Just colleague.unPrincipalId)) `shouldSatisfyIO` isRight
    audit <- withDb pool (query "SELECT count(*) FROM memory_mutations" ())
    audit `shouldBe` [Only (2 :: Int64)]

  it "repairs only an orphan subject proven by unique account mapping and original message evidence" $ do
    (_, message, actor) <- seed pool 900 2783846439
    (_, _, other) <- seed pool 900 777777777
    let conversation = conversationScopeFor (GroupId 900)
        draft = MemoryDraft "explicit permanent fact" MemoryPermanent Nothing (MessageEvidence conversation (Just actor.unPrincipalId) message.unCanonicalMessageId)
    orphan <- withDb pool $ Store.createMemory (MemoryActor ActorAdmin Nothing (Just "legacy fixture")) (userMemoryNamespace conversation 2783846439) draft
    let repair person = withDb pool $ Store.repairMemorySubjectAdmin conversation orphan.memId (ExpectedVersion orphan.memVersion) person "verified native identity and source message"
    repair other.unPrincipalId `shouldReturn` MemoryMutationRejected
    result <- repair actor.unPrincipalId
    case result of
      MemoryMutationApplied memory -> do
        memory.memScopeId `shouldBe` actor.unPrincipalId
        memory.memVersion `shouldBe` MemoryVersion 2
        memory.memLifecycle `shouldBe` "permanent"
        memory.memContent `shouldBe` "explicit permanent fact"
      _ -> expectationFailure "proven orphan was not repaired"
    repair actor.unPrincipalId `shouldReturn` MemoryMutationRejected
    audit <- withDb pool $ query "SELECT operation,reason LIKE '%2783846439 -> %' FROM memory_mutations WHERE from_version=1" ()
    audit `shouldBe` [("backfill" :: Text, True)]
  where
    isInvalid (MemoryContentInvalid _) = True
    isInvalid _ = False

shouldSatisfyIO :: (Show a) => IO a -> (a -> Bool) -> Expectation
shouldSatisfyIO action predicate = action >>= (`shouldSatisfy` predicate)
