-- |
-- End-to-end test for 'Max.Prompt.buildContext' against a real
-- database: insert fixture rows, drive 'buildContext' through the
-- effect stack, then assert on the rendered ChatMessage list.  The
-- pure render path is covered separately in 'Max.PromptSpec'; this
-- module specifically verifies that the DB queries wire up to the
-- renderer correctly (token-budgeted raw fallback, compartments, pin
-- resolution, and reply lookup).
module Max.PromptIntegrationSpec (spec) where

import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Database.PostgreSQL.Simple (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (insertMessageWithCanonicalId, insertRawKind, insertRawMessage, requireJust, truncateAll, updateDbSession, withDb, withDbLog)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.History (LedgerItem (..), MessageCursor (..))
import Max.DB.Session (fetchOrInit)
import Max.DB.Transaction (withReadSnapshot)
import Max.Dispatch (DispatchMessage (..))
import Max.Effects.LLM (ChatMessage (..))
import Max.EpisodeStore
import Max.IR (Body (..), MentionTarget (MentionIdentity), Node (..))
import Max.ModelCatalog (ContextLimits (..), defaultContextLimits)
import Max.Platform.Types (CanonicalMessageId (..), Platform (PlatformQQ), PrincipalId (..), PrincipalIdentityId (..))
import Max.Prompt (ContextReadMode (..), PromptRequest (..), buildContext, planContext, renderContextPlan)
import Max.Prompt.Collect (collectContextPreview)
import Max.Prompt.History (fetchBoundedPromptTail)
import Max.Session (Session (..))
import OneBot.Types (GroupId (..), UserId (..))
import PromptFixture (promptRequest)
import Test.Hspec

groupRaw :: (Integral a) => a
groupRaw = 7777

botRaw :: (Integral a) => a
botRaw = 1000

memberRaw :: (Integral a) => a
memberRaw = 2001

otherMemberRaw :: (Integral a) => a
otherMemberRaw = 2002

timeAt :: Int -> UTCTime
timeAt h =
  UTCTime
    (fromGregorian 2026 6 5)
    (secondsToDiffTime (fromIntegral (h * 3600)))

trigger :: DispatchMessage
trigger =
  DispatchMessage
    { selfId = UserId botRaw,
      groupId = GroupId groupRaw,
      userId = UserId memberRaw,
      selfPrincipalId = PrincipalId 1,
      authorPrincipalId = PrincipalId 2,
      canonicalId = CanonicalMessageId 9000,
      body = Body [NMention (MentionIdentity (PrincipalIdentityId 1)) "Max", NText " 现在几点"],
      replyTo = Nothing,
      senderDisplayName = Just "Alice",
      sourcePlatform = PlatformQQ,
      mentionPrincipals = Map.singleton (PrincipalIdentityId 1) (PrincipalId 1)
    }

userBodyOf :: [ChatMessage] -> Text
userBodyOf msgs = case last msgs of
  MsgUser t -> t
  other -> error $ "expected trailing MsgUser, got: " <> show other

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $
  describe "Max.Prompt.buildContext (integration)" $ do
    it "renders ambient rows from the messages table" $ do
      insertMessageWithCanonicalId pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "随便聊"
      insertMessageWithCanonicalId pool 1002 groupRaw memberRaw botRaw (timeAt 10) (Just "Alice") "另一条"
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      msgs <-
        withDbLog pool $ fst <$> buildContext (promptRequest s trigger)
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("随便聊" `T.isInfixOf`)
      ub `shouldSatisfy` ("另一条" `T.isInfixOf`)

    it "honours cleared_at watermark — older rows are dropped" $ do
      insertMessageWithCanonicalId pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "旧"
      insertMessageWithCanonicalId pool 1002 groupRaw memberRaw botRaw (timeAt 11) (Just "Alice") "新"
      s <-
        updateDbSession pool (GroupId groupRaw) "deepseek-flash" $ \current ->
          current {clearedAt = Just (timeAt 10)}
      msgs <- withDbLog pool $ fst <$> buildContext (promptRequest s trigger)
      let ub = userBodyOf msgs
      ub `shouldNotSatisfy` ("旧" `T.isInfixOf`)
      ub `shouldSatisfy` ("新" `T.isInfixOf`)

    it "renders prior @-mention and the bot's reply as transcript lines" $ do
      insertMessageWithCanonicalId pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "@1000 你好"
      insertMessageWithCanonicalId pool 1002 groupRaw botRaw botRaw (timeAt 10) Nothing "你好 Alice"
      _ <- withDb pool $ execute "UPDATE messages SET is_synthetic = true WHERE message_id = ?" (Only (1002 :: Int64))
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      msgs <- withDbLog pool $ fst <$> buildContext (promptRequest s trigger)
      -- The whole conversation is [system, user]: the bot's own past
      -- replies are lines in the transcript, not assistant turns.
      length msgs `shouldBe` 2
      case msgs of
        [MsgSystem _, MsgUser ub] -> do
          ub `shouldSatisfy` ("[09:00 Alice #1001]:" `T.isInfixOf`)
          ub `shouldSatisfy` ("[10:00 Max #1002]: 你好 Alice" `T.isInfixOf`)
        other -> expectationFailure $ "unexpected message shape: " <> show other

    it "keeps one chronological raw stream before the first compartment" $ do
      insertMessageWithCanonicalId pool 1001 groupRaw memberRaw botRaw (timeAt 1) (Just "Alice") "@1000 昨天那事呢"
      insertMessageWithCanonicalId pool 1002 groupRaw botRaw botRaw (timeAt 2) Nothing "已经办好了"
      mapM_
        ( \i ->
            insertMessageWithCanonicalId pool (2000 + i) groupRaw otherMemberRaw botRaw (timeAt (3 + fromIntegral i)) (Just "Bob") ("闲聊" <> T.pack (show i))
        )
        [1 .. 5 :: Int64]
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      msgs <- withDbLog pool $ fst <$> buildContext (promptRequest s trigger)
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("昨天那事呢" `T.isInfixOf`)
      ub `shouldSatisfy` ("已经办好了" `T.isInfixOf`)
      ub `shouldSatisfy` ("闲聊5" `T.isInfixOf`)

    it "renders one chronological compartment stream plus its complete raw tail" $ do
      insertMessageWithCanonicalId pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "settled raw one"
      insertMessageWithCanonicalId pool 1002 groupRaw botRaw botRaw (timeAt 10) Nothing "settled raw two"
      let scope = conversationScopeFor (GroupId groupRaw)
      end <- cursorFor pool 1002
      run <-
        withDb
          pool
          ( prepareCaptureRun
              scope
              (MessageCursor 0)
              end
              CaptureRequest
                { requestReason = CaptureIdle,
                  requestHistorianProfile = "test",
                  requestPromptVersion = "historian/test",
                  requestSchemaVersion = 1
                }
          )
          >>= requireJust "capture run"

      source <- withDb pool $ loadCaptureSource run
      let capture =
            EpisodeCapture
              { captureSummaryP1 = CitedSummary "settled full summary" [1001, 1002],
                captureSummaryP2 = CitedSummary "settled full summary" [1001, 1002],
                captureSummaryP3 = CitedSummary "settled full summary" [1001, 1002],
                captureImportance = 0.8,
                captureConfidence = 1,
                captureEpisodeKind = MaxInteraction,
                captureMemoryProposals = []
              }
      validated <- case validateEpisodeCapture run source capture of
        Right value -> pure value
        Left errors -> expectationFailure (show errors) >> error "invalid capture"
      _ <- withDb pool $ publishCaptureRun scope run "fixture response" validated
      insertMessageWithCanonicalId pool 1003 groupRaw otherMemberRaw botRaw (timeAt 11) (Just "Bob") "ambient raw tail"

      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      msgs <-
        withDbLog pool $
          fst <$> buildContext ((promptRequest s trigger) {prLimits = defaultContextLimits})
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("settled full summary" `T.isInfixOf`)
      ub `shouldSatisfy` ("ambient raw tail" `T.isInfixOf`)
      ub `shouldSatisfy` (not . ("settled raw one" `T.isInfixOf`))
      rawEmergency <-
        withDbLog pool $
          fst <$> buildContext ((promptRequest s trigger) {prReadMode = RawLedgerEmergency})
      userBodyOf rawEmergency `shouldSatisfy` ("settled raw one" `T.isInfixOf`)
      userBodyOf rawEmergency `shouldSatisfy` (not . ("settled full summary" `T.isInfixOf`))

    it "reads newly published summaries immediately without durable prompt state" $ do
      insertMessageWithCanonicalId pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "first settled range"
      (_, firstEnd) <- publishNextCompartment pool (MessageCursor 0) [1001] "first summary"
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      let request = (promptRequest s trigger) {prLimits = ContextLimits 8000 512 0 0}
          build = withDbLog pool $ withReadSnapshot $ fst <$> buildContext request
      first <- build
      userBodyOf first `shouldSatisfy` ("first summary" `T.isInfixOf`)
      insertMessageWithCanonicalId pool 1002 groupRaw otherMemberRaw botRaw (timeAt 10) (Just "Bob") "newly settled source"
      _ <- publishNextCompartment pool firstEnd [1002] "second summary"
      second <- build
      userBodyOf second `shouldSatisfy` ("second summary" `T.isInfixOf`)
      userBodyOf second `shouldSatisfy` (not . ("newly settled source" `T.isInfixOf`))
      snapshot <- withDbLog pool $ withReadSnapshot (collectContextPreview request)
      userBodyOf (renderContextPlan (planContext request.prLimits snapshot)) `shouldBe` userBodyOf second
      [Only materializations] <- withDb pool $ query "SELECT count(*) FROM context_materializations" ()
      [Only traces] <- withDb pool $ query "SELECT count(*) FROM context_plan_traces" ()
      (materializations :: Int64) `shouldBe` 0
      (traces :: Int64) `shouldBe` 0

    -- Everything the chat saw is in the table; only `kind = 'chat'`
    -- reaches the model.  Load-bearing for !btw in particular: its
    -- command message used to sit in the transcript as a question, and
    -- a later turn would answer it again.
    it "shows only kind='chat' rows in the transcript" $ do
      insertMessageWithCanonicalId pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "普通聊天"
      _ <- insertRawKind pool "command" 1002 groupRaw memberRaw botRaw (timeAt 10) (Just "Alice") "!btw 顺便问一下"
      _ <- insertRawKind pool "command" 1003 groupRaw botRaw botRaw (timeAt 11) (Just "max") "在跑的任务: t3"
      _ <- insertRawKind pool "debug" 1004 groupRaw botRaw botRaw (timeAt 12) (Just "max") "⚙ web_search {\"q\":\"foo\"}"
      _ <- insertRawKind pool "debug" 1005 groupRaw botRaw botRaw (timeAt 13) (Just "max") "↳ web_search {\"results\":[]}"
      -- The bot's narration is conversation, so it stays.
      insertMessageWithCanonicalId pool 1006 groupRaw botRaw botRaw (timeAt 14) (Just "max") "我查一下日志"
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      msgs <- withDbLog pool $ fst <$> buildContext (promptRequest s trigger)
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("普通聊天" `T.isInfixOf`)
      ub `shouldSatisfy` ("我查一下日志" `T.isInfixOf`)
      ub `shouldSatisfy` (not . ("顺便问一下" `T.isInfixOf`))
      ub `shouldSatisfy` (not . ("在跑的任务" `T.isInfixOf`))
      ub `shouldSatisfy` (not . ("⚙" `T.isInfixOf`))
      ub `shouldSatisfy` (not . ("↳" `T.isInfixOf`))

    it "retains 200 short raw messages when the model token budget permits" $ do
      mapM_
        (\i -> insertRawMessage pool (3000 + i) groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") ("短消息" <> T.pack (show i)))
        [1 .. 200 :: Int64]
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      msgs <- withDbLog pool $ fst <$> buildContext ((promptRequest s trigger) {prLimits = ContextLimits 100000 1024 0 0})
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("短消息1" `T.isInfixOf`)
      ub `shouldSatisfy` ("短消息200" `T.isInfixOf`)

    it "keeps only the newest token-bounded tail from an arbitrarily longer raw ledger" $ do
      mapM_
        ( \n ->
            insertRawMessage
              pool
              (4000 + n)
              groupRaw
              memberRaw
              botRaw
              (timeAt 9)
              (Just "Alice")
              ( (if n == 1 then "oldest-sentinel " else if n == 1200 then "newest-sentinel " else "")
                  <> T.replicate 20 "bounded-history "
              )
        )
        [1 .. 1200 :: Int64]
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      msgs <-
        withDbLog pool $
          fst <$> buildContext ((promptRequest s trigger) {prLimits = ContextLimits 8000 1024 0 0})
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("newest-sentinel" `T.isInfixOf`)
      ub `shouldSatisfy` (not . ("oldest-sentinel" `T.isInfixOf`))

    it "shows each raw-ledger message exactly once" $ do
      insertMessageWithCanonicalId pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "@1000 只此一次"
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      msgs <- withDbLog pool $ fst <$> buildContext (promptRequest s trigger)
      T.count "只此一次" (userBodyOf msgs) `shouldBe` 1

    it "renders pinned messages in the [pinned] section" $ do
      insertMessageWithCanonicalId pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "重要信息"
      s <-
        updateDbSession pool (GroupId groupRaw) "deepseek-flash" $ \current ->
          current {pinned = [1001]}
      msgs <- withDbLog pool $ fst <$> buildContext (promptRequest s trigger)
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("[pinned" `T.isInfixOf`)
      ub `shouldSatisfy` ("重要信息" `T.isInfixOf`)

    it "renders reply context when trigger has SegReply" $ do
      quoted <- insertRawMessage pool 1001 groupRaw memberRaw botRaw (timeAt 9) (Just "Alice") "被引用的话"
      s <- withDb pool $ fetchOrInit (GroupId groupRaw) "deepseek-flash"
      let replyTrigger =
            trigger
              { body = Body [NMention (MentionIdentity (PrincipalIdentityId 1)) "Max", NText " 看这条"],
                replyTo = Just (CanonicalMessageId quoted)
              }
      msgs <- withDbLog pool $ fst <$> buildContext (promptRequest s replyTrigger)
      let ub = userBodyOf msgs
      ub `shouldSatisfy` ("[quoted context]" `T.isInfixOf`)
      ub `shouldSatisfy` ("被引用的话" `T.isInfixOf`)

    it "reports omitted raw history when the historian is behind" $ do
      insertMessageWithCanonicalId pool 1001 groupRaw memberRaw botRaw (timeAt 1) (Just "Alice") "folded one"
      insertMessageWithCanonicalId pool 1002 groupRaw memberRaw botRaw (timeAt 2) (Just "Alice") "folded two"
      (_, end) <- publishNextCompartment pool (MessageCursor 0) [1001, 1002] "folded summary"
      -- More raw rows after the last compartment than one fetch page (256),
      -- and far more tokens than the fetch budget. Truncation stays observable.
      mapM_
        (\i -> insertRawMessage pool (2000 + i) groupRaw otherMemberRaw botRaw (timeAt 3) (Just "Bob") ("burst " <> T.pack (show i)))
        [1 .. 260 :: Int64]
      let scope = conversationScopeFor (GroupId groupRaw)
      (tailRows, tailDropped) <-
        withDb pool $ fetchBoundedPromptTail scope end 9000 Nothing 128
      tailDropped `shouldBe` True
      case tailRows of
        oldest : _ -> oldest.cursor.ingestSeq `shouldSatisfy` (> end.ingestSeq)
        [] -> expectationFailure "expected a bounded raw tail"

cursorFor :: DbPool -> Int64 -> IO MessageCursor
cursorFor pool messageId = do
  rows <- withDb pool $ query "SELECT ingest_seq FROM messages WHERE message_id = ?" (Only messageId)
  case rows :: [Only Int64] of
    Only cursor : _ -> pure (MessageCursor cursor)
    _ -> expectationFailure "missing message cursor" >> pure (MessageCursor 0)

publishNextCompartment :: DbPool -> MessageCursor -> [Int64] -> Text -> IO (CompartmentId, MessageCursor)
publishNextCompartment pool expected evidence summary = do
  end <- cursorFor pool (last evidence)
  let scope = conversationScopeFor (GroupId groupRaw)
  run <-
    withDb
      pool
      ( prepareCaptureRun
          scope
          expected
          end
          CaptureRequest
            { requestReason = CaptureIdle,
              requestHistorianProfile = "test",
              requestPromptVersion = "historian/test",
              requestSchemaVersion = 1
            }
      )
      >>= requireJust "capture run"

  source <- withDb pool $ loadCaptureSource run
  let capture =
        EpisodeCapture
          { captureSummaryP1 = CitedSummary summary evidence,
            captureSummaryP2 = CitedSummary summary evidence,
            captureSummaryP3 = CitedSummary summary evidence,
            captureImportance = 0.8,
            captureConfidence = 1,
            captureEpisodeKind = Mixed,
            captureMemoryProposals = []
          }
  validated <- case validateEpisodeCapture run source capture of
    Right value -> pure value
    Left errors -> expectationFailure (show errors) >> error "invalid capture"
  compartment <- withDb pool $ publishCaptureRun scope run "fixture response" validated
  pure (compartment, end)
