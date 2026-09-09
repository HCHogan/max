module Max.MemoryMaintenanceSpec (spec) where

import Control.Monad (void)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (fromGregorian, utc)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful (liftIO)
import Effectful.Concurrent (runConcurrent)
import Effectful.PostgreSQL (execute, query)
import Helpers (insertRawMessage, testTime, truncateAll, withDb, withDbLog)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.Effects.LLM (ChatMessage (..), ChatResponse (..), LLMInterpreter (..), runLLMWith)
import Max.Memory.Maintenance
import Max.MemoryStore
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "causal memory maintenance" $ do
  let scope = conversationScopeFor (GroupId 1090284918)
      namespace = groupMemoryNamespace scope
      actor = MemoryActor ActorHistorian Nothing Nothing
      evidence identifier = MessageEvidence scope Nothing identifier
      remember identifier text = withDb pool (createMemory actor namespace (MemoryDraft text MemoryActive Nothing (evidence identifier)))
      message user text = insertRawMessage pool 1 1090284918 user 99 testTime Nothing text
  it "queues even a single-entry namespace exactly once and uses legacy group for message scope" $ do
    source <- message 1 "初试先现场查资料，复试才考 C"
    _ <- remember source "复试考 C"
    [Only canonical] <- withDb pool (query "SELECT conversation_id FROM messages WHERE canonical_message_id=?" (Only source))
    (canonical :: Int64) `shouldNotBe` 1090284918
    withDb pool enqueueMemoryMaintenance `shouldReturn` 1
    withDb pool enqueueMemoryMaintenance `shouldReturn` 0
    [Only actual] <- withDb pool (query "SELECT message_id FROM memory_human_sources" ())
    (actual :: Int64) `shouldBe` source
  it "coalesces a namespace review and includes later human discussion without self-reinforcement" $ do
    source <- message 1 "早期事实"
    _ <- remember source "早期事实一"
    _ <- remember source "早期事实二"
    _ <- insertRawMessage pool 2 1090284918 2 99 testTime Nothing "后续更正还没有写入记忆"
    calls <- newIORef []
    let model =
          LLMInterpreter
            ( \_ _ messages _ _ -> do
                liftIO (modifyIORef' calls (messages :))
                pure (Right (ContentResp "[]"))
            )
        runPass = withDbLog pool . runConcurrent . runLLMWith model $ memoryMaintenancePass "test" "fake" utc 10000
    runPass
    requests <- readIORef calls
    length requests `shouldBe` 1
    concat [texts | messages <- requests, let { texts = [text | MsgUser text <- messages] }] `shouldSatisfy` any (T.isInfixOf "后续更正还没有写入记忆")
    runPass
    length <$> readIORef calls `shouldReturn` 1
    [Only pendingCount] <- withDb pool (query "SELECT count(*) FROM memory_maintenance_events WHERE finished_at IS NULL" ())
    (pendingCount :: Int64) `shouldBe` 0

  it "retains pending evidence when the configured model budget cannot fit a review" $ do
    source <- message 1 "需要核实的原始事实"
    _ <- remember source "需要核实的原始事实"
    let model = LLMInterpreter (\_ _ _ _ _ -> liftIO (expectationFailure "over-budget maintenance reached provider") >> pure (Right (ContentResp "[]")))
    withDbLog pool . runConcurrent . runLLMWith model $ memoryMaintenancePass "test" "fake" utc 1
    [Only outcome] <- withDb pool (query "SELECT outcome FROM memory_maintenance_events WHERE finished_at IS NULL" ())
    (outcome :: Text) `shouldSatisfy` T.isPrefixOf "input budget exceeded"

  it "rejects bot self-citation and maintenance notes as new evidence" $ do
    bot <- message 99 "Max 重复了旧事实"
    _ <- remember bot "旧事实"
    _ <-
      withDb
        pool
        ( createMemory
            (MemoryActor ActorDreamer Nothing Nothing)
            namespace
            (MemoryDraft "整理说明" MemoryActive Nothing (MaintenanceEvidence scope "再次检索"))
        )
    withDb pool enqueueMemoryMaintenance `shouldReturn` 0
  it "does not treat forwarded historical text as a new independent human observation" $ do
    parent <- message 1 "转发聊天记录"
    child <- insertRawMessage pool 2 1090284918 2 99 testTime Nothing "很早以前的说法"
    void $ withDb pool (execute "INSERT INTO message_relations(canonical_message_id,relation_kind,target_canonical_message_id,relation_position) VALUES(?,'contained_in',?,0)" (child, parent))
    _ <- remember child "很早以前的说法"
    withDb pool enqueueMemoryMaintenance `shouldReturn` 0

  it "supersedes only with a newer exact human citation and both current versions" $ do
    first <- message 1 "初试考 C"
    old <- remember first "初试考 C"
    next <- insertRawMessage pool 2 1090284918 1 99 testTime Nothing "更正：初试现场学习，复试考 C"
    replacement <- remember next "初试现场学习，复试考 C"
    let proposal version = Replace old.memId old.memVersion replacement.memId version next "较晚原文明确更正"
    withDb pool (applyMaintenanceProposal scope utc (proposal (MemoryVersion 2))) `shouldReturn` "rejected"
    withDb pool (applyMaintenanceProposal (conversationScopeFor (GroupId 42)) utc (proposal replacement.memVersion)) `shouldReturn` "rejected"
    withDb pool (applyMaintenanceProposal scope utc (proposal replacement.memVersion)) `shouldReturn` "applied"
    withDb pool (applyMaintenanceProposal scope utc (proposal replacement.memVersion)) `shouldReturn` "rejected"
    [Only state] <- withDb pool (query "SELECT lifecycle FROM memories WHERE id=?" (Only old.memId))
    (state :: Text) `shouldBe` "superseded"
  it "does not treat a newer rewording with the same source as independent evidence" $ do
    source <- message 1 "今天是初试"
    old <- remember source "初试"
    replacement <- remember source "今天初试"
    withDb pool (applyMaintenanceProposal scope utc (Replace old.memId old.memVersion replacement.memId replacement.memVersion source "相同来源")) `shouldReturn` "rejected"
  it "expires explicit dated facts and fences a changed version before expiry" $ do
    source <- message 1 "优惠有效期截至 2026-01-01"
    old <- remember source "优惠有效期截至 2026-01-01"
    let proposal = Expire old.memId old.memVersion source (fromGregorian 2026 1 1) "原始期限"
    withDb pool (applyMaintenanceProposal scope utc proposal) `shouldReturn` "scheduled"
    withDb pool expireDueMemories `shouldReturn` 1
    withDb pool expireDueMemories `shouldReturn` 0
    changed <- remember source "另一项截至 2026-01-01"
    withDb pool (applyMaintenanceProposal scope utc (Expire changed.memId changed.memVersion source (fromGregorian 2026 1 1) "期限")) `shouldReturn` "scheduled"
    void $ withDb pool (updateMemory actor namespace changed.memId (ExpectedVersion changed.memVersion) (MemoryUpdate "已延期" (evidence source)))
    withDb pool expireDueMemories `shouldReturn` 0
  it "invalidates a scheduled expiry when the cited original message is edited" $ do
    source <- message 1 "优惠有效期截至 2026-01-01"
    old <- remember source "优惠有效期截至 2026-01-01"
    withDb pool (applyMaintenanceProposal scope utc (Expire old.memId old.memVersion source (fromGregorian 2026 1 1) "原始期限")) `shouldReturn` "scheduled"
    void $ withDb pool (execute "UPDATE messages SET rendered_text='期限已更正，请重新核实' WHERE canonical_message_id=?" (Only source))
    withDb pool expireDueMemories `shouldReturn` 0

  it "rejects inferred dates and never auto-archives a permanent fact" $ do
    source <- message 1 "旧任务早就结束了"
    old <- remember source "旧任务早就结束了"
    withDb pool (applyMaintenanceProposal scope utc (Expire old.memId old.memVersion source (fromGregorian 2026 1 1) "猜测日期")) `shouldReturn` "rejected"
    dated <- insertRawMessage pool 2 1090284918 1 99 testTime Nothing "截止 2026-01-01"
    permanent <- withDb pool (createMemory (MemoryActor ActorAdmin Nothing Nothing) namespace (MemoryDraft "截止 2026-01-01" MemoryPermanent Nothing (evidence dated)))
    withDb pool (applyMaintenanceProposal scope utc (Expire permanent.memId permanent.memVersion dated (fromGregorian 2026 1 1) "已过期")) `shouldReturn` "rejected"
