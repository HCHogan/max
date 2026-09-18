module Max.MemoryExpirySpec (spec) where

import Control.Monad (void)
import Data.Int (Int64)
import Data.Text (Text)
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (insertRawMessage, testTime, truncateAll, withDb)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.Memory.Expiry (expireDueMemories)
import Max.MemoryStore
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "recorded memory expiry" $ do
  let scope = conversationScopeFor (GroupId 1090284918)
      namespace = groupMemoryNamespace scope
      actor = MemoryActor ActorHistorian Nothing Nothing
      evidence identifier = MessageEvidence scope Nothing identifier
      remember source = withDb pool (createMemory actor namespace (MemoryDraft "优惠截至 2026-01-01" MemoryActive Nothing (evidence source)))
      sourceMessage = insertRawMessage pool 1 1090284918 1 99 testTime Nothing "优惠截至 2026-01-01"
      schedule memory source (delay :: Int) =
        void . withDb pool $
          execute
            "INSERT INTO memory_expirations(memory_id,memory_version,source_message_id,expires_on,due_at,reason,source_text_hash)\
            \ SELECT ?,?,?,DATE '2026-01-01',now()+(? * interval '1 second'),'recorded expiry',md5(rendered_text)\
            \ FROM messages WHERE canonical_message_id=?"
            (memory.memId, memory.memVersion, source, delay, source :: Int64)

  it "expires a recorded date once without calling a model" $ do
    source <- sourceMessage
    memory <- remember source
    schedule memory source (-1)
    withDb pool expireDueMemories `shouldReturn` 1
    withDb pool expireDueMemories `shouldReturn` 0
    rows <- withDb pool $ query "SELECT lifecycle FROM memories WHERE id=?" (Only memory.memId)
    rows `shouldBe` [Only ("archived" :: Text)]

  it "leaves future dates pending" $ do
    source <- sourceMessage
    memory <- remember source
    schedule memory source 3600
    withDb pool expireDueMemories `shouldReturn` 0
    rows <- withDb pool $ query "SELECT finished_at IS NULL FROM memory_expirations WHERE memory_id=?" (Only memory.memId)
    rows `shouldBe` [Only True]

  it "does not expire a memory updated after scheduling" $ do
    source <- sourceMessage
    memory <- remember source
    schedule memory source (-1)
    void $ withDb pool (updateMemory actor namespace memory.memId (ExpectedVersion memory.memVersion) (MemoryUpdate "已延期" (evidence source)))
    withDb pool expireDueMemories `shouldReturn` 0

  it "rejects expiry after the cited message changes" $ do
    source <- sourceMessage
    memory <- remember source
    schedule memory source (-1)
    void $ withDb pool (execute "UPDATE messages SET rendered_text='期限已更正' WHERE canonical_message_id=?" (Only source))
    withDb pool expireDueMemories `shouldReturn` 0

  it "never automatically archives permanent memories" $ do
    source <- sourceMessage
    memory <- withDb pool (createMemory (MemoryActor ActorAdmin Nothing Nothing) namespace (MemoryDraft "永久保留" MemoryPermanent Nothing (evidence source)))
    schedule memory source (-1)
    withDb pool expireDueMemories `shouldReturn` 0
