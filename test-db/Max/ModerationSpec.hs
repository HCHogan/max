module Max.ModerationSpec (spec) where

import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Effectful (IOE, (:>))
import Effectful.Log (Log)
import Effectful.PostgreSQL (WithConnection)
import Helpers (insertRawMessage, testTime, truncateAll, withDbLog)
import Max.Conversation.ToolRuntime (moderationToolsWithDatabase)
import Max.DB.Connection (DbPool, withConn)
import Max.Effects.PlatformModeration (PlatformModeration, runPlatformModeration)
import Max.Effects.PlatformQuery (PlatformQuery, runPlatformQuery)
import Max.Effects.Tools (Tool (..), ToolOutcome (..), ToolRunner (..))
import Max.Platform (PlatformBackend (..))
import Max.IR (Body (..), Node (NText))
import Max.Platform.Rpc (platformRouter)
import Max.Platform.Store.Outbound (EnqueuedOutbound (..), OutboundDraft (..), enqueueOutbound)
import Max.Platform.Types (CanonicalMessageId (..), PrincipalId (..), noAdvertisedCaps)
import Max.ToolContext (TurnCapabilities (..), TurnIdentity (..), mkToolContext)
import OneBot.Action (Action (..), Response (..))
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))
import Test.Hspec

-- Fixture ids only: group 42, Max 9, owner 6, administrator 8, member 7.
group :: GroupId
group = GroupId 42

self :: Int64
self = 9

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "QQ moderation tools" $ do
  it "recalls a member's message by its canonical id" $ do
    message <- insertRawMessage pool 501 42 7 self testTime (Just "member") "spam"
    (outcome, calls) <- runTool pool (roster "admin") "recall_message" (object ["message_id" .= message])
    outcome `shouldBe` ToolCommitted (object ["ok" .= True, "recalled" .= (1 :: Int)])
    calls `shouldBe` [Recall group (MessageId 501)]

  it "recalls every part of Max's own reply, counting its echo once" $ do
    _ <- insertRawMessage pool 501 42 7 self testTime (Just "member") "question"
    reply <- withDbLog pool (enqueueOutbound (OutboundDraft 42 "chat" Nothing (Body [NText "part one\n\npart two"]) Nothing Nothing Nothing))
    let CanonicalMessageId canonical = reply.canonicalMessageId
    withConn pool $ \c ->
      mapM_
        ( \(index, native) ->
            execute
              c
              "INSERT INTO message_delivery_parts (delivery_id, part_index, fingerprint, idempotency_key, status, native_event_id) \
              \ SELECT delivery_id, ?, 'fixture', ?, 'confirmed', ? FROM message_deliveries WHERE canonical_message_id = ?"
              (index :: Int, "fixture:" <> native, native, canonical)
        )
        [(0, "601"), (1, "602" :: Text)]
    -- QQ reports Max's own first part back; ingest folds it into the reply.
    echo <- insertRawMessage pool 601 42 self self testTime (Just "Max") "part one"
    echo `shouldBe` canonical
    -- A plain member may still recall its own messages; QQ enforces the window.
    (outcome, calls) <- runTool pool (roster "member") "recall_message" (object ["message_id" .= canonical])
    outcome `shouldBe` ToolCommitted (object ["ok" .= True, "recalled" .= (2 :: Int)])
    calls `shouldBe` [Recall group (MessageId 601), Recall group (MessageId 602)]

  it "refuses another member's message when Max is not an administrator" $ do
    message <- insertRawMessage pool 501 42 7 self testTime (Just "member") "spam"
    (outcome, calls) <- runTool pool (roster "member") "recall_message" (object ["message_id" .= message])
    refused outcome `shouldBe` True
    calls `shouldBe` []

  it "refuses an administrator's message unless Max owns the group" $ do
    message <- insertRawMessage pool 502 42 8 self testTime (Just "admin") "notice"
    (asAdmin, adminCalls) <- runTool pool (roster "admin") "recall_message" (object ["message_id" .= message])
    refused asAdmin `shouldBe` True
    adminCalls `shouldBe` []
    (asOwner, ownerCalls) <- runTool pool ownedRoster "recall_message" (object ["message_id" .= message])
    asOwner `shouldBe` ToolCommitted (object ["ok" .= True, "recalled" .= (1 :: Int)])
    ownerCalls `shouldBe` [Recall group (MessageId 502)]

  it "cannot reach a message in another group" $ do
    _ <- insertRawMessage pool 501 42 7 self testTime (Just "member") "here"
    elsewhere <- insertRawMessage pool 701 43 7 self testTime (Just "member") "elsewhere"
    (outcome, calls) <- runTool pool (roster "admin") "recall_message" (object ["message_id" .= elsewhere])
    refused outcome `shouldBe` True
    calls `shouldBe` []

  it "reports a rejected recall as a failure, not as done" $ do
    message <- insertRawMessage pool 501 42 7 self testTime (Just "member") "old"
    (outcome, calls) <- runToolWith pool (roster "admin") (Just 1200) "recall_message" (object ["message_id" .= message])
    case outcome of
      ToolFailedBeforeEffect _ -> pure ()
      other -> expectationFailure ("expected a failure, got " <> show other)
    calls `shouldBe` [Recall group (MessageId 501)]

  it "mutes and unmutes a member named by principal" $ do
    _ <- insertRawMessage pool 501 42 7 self testTime (Just "member") "spam"
    member <- principalOf pool "7"
    (muted, muteCalls) <- runTool pool (roster "admin") "mute_member" (object ["member" .= member, "seconds" .= (600 :: Int)])
    muted `shouldBe` ToolCommitted (object ["ok" .= True, "seconds" .= (600 :: Int)])
    muteCalls `shouldBe` [Ban group (UserId 7) 600]
    (lifted, liftCalls) <- runTool pool (roster "admin") "mute_member" (object ["member" .= member, "seconds" .= (0 :: Int)])
    lifted `shouldBe` ToolCommitted (object ["ok" .= True, "seconds" .= (0 :: Int)])
    liftCalls `shouldBe` [Ban group (UserId 7) 0]

  it "refuses mutes QQ would refuse, before calling it" $ do
    _ <- insertRawMessage pool 501 42 7 self testTime (Just "member") "spam"
    _ <- insertRawMessage pool 502 42 8 self testTime (Just "admin") "hi"
    _ <- insertRawMessage pool 503 42 6 self testTime (Just "owner") "hi"
    [member, admin, owner] <- mapM (principalOf pool) ["7", "8", "6"]
    let mute who seconds = runTool pool (roster "admin") "mute_member" (object ["member" .= who, "seconds" .= (seconds :: Int)])
    results <- sequence [mute admin 60, mute owner 60, mute member (31 * 24 * 3600)]
    map (refused . fst) results `shouldBe` [True, True, True]
    concatMap snd results `shouldBe` []
    (asMember, calls) <- runTool pool (roster "member") "mute_member" (object ["member" .= member, "seconds" .= (60 :: Int)])
    refused asMember `shouldBe` True
    calls `shouldBe` []

  it "refuses a conversation without a QQ group endpoint" $ do
    (outcome, calls) <- runToolIn pool (GroupId 4242) (roster "admin") Nothing "recall_message" (object ["message_id" .= (1 :: Int)])
    refused outcome `shouldBe` True
    calls `shouldBe` []
  where
    roster :: Text -> [(Int64, Text)]
    roster selfRole = [(self, selfRole), (6, "owner"), (8, "admin"), (7, "member")]
    ownedRoster = [(self, "owner"), (8, "admin"), (7, "member")]

-- | The moderation actions the fake NapCat received.
data Call = Recall GroupId MessageId | Ban GroupId UserId Int
  deriving stock (Eq, Show)

refused :: ToolOutcome -> Bool
refused = \case
  ToolFailedBeforeEffect _ -> True
  _ -> False

principalOf :: DbPool -> Text -> IO Int64
principalOf pool native =
  withConn pool $ \c -> do
    [Only principal] <- query c "SELECT principal_id FROM principal_identities WHERE native_user_id = ?" (Only native)
    pure principal

runTool :: DbPool -> [(Int64, Text)] -> Text -> Value -> IO (ToolOutcome, [Call])
runTool pool members = runToolWith pool members Nothing

runToolWith :: DbPool -> [(Int64, Text)] -> Maybe Int -> Text -> Value -> IO (ToolOutcome, [Call])
runToolWith pool = runToolIn pool group

-- | Run one tool against a fake NapCat that answers the member list and
-- records every moderation action, rejecting them with @retcode@ if given.
runToolIn :: DbPool -> GroupId -> [(Int64, Text)] -> Maybe Int -> Text -> Value -> IO (ToolOutcome, [Call])
runToolIn pool target members retcode name args = do
  calls <- newIORef []
  let backend = napcat calls members retcode
      turn =
        mkToolContext
          (TurnIdentity target (CanonicalMessageId 1) (UserId 7) (UserId self) (PrincipalId 1) Nothing Nothing)
          (TurnCapabilities False False False noAdvertisedCaps False Map.empty Nothing False)
      tools :: (PlatformModeration :> es, PlatformQuery :> es, Log :> es, WithConnection :> es, IOE :> es) => [Tool es]
      tools = moderationToolsWithDatabase turn
  outcome <-
    withDbLog pool . runPlatformModeration (platformRouter backend (pure [])) . runPlatformQuery (platformRouter backend (pure [])) $
      case find ((== name) . (.toolName)) tools of
        Just Tool {toolRunner = OutcomeRunner run} -> run args
        _ -> error ("no outcome runner for " <> show name)
  (outcome,) <$> readIORef calls

napcat :: IORef [Call] -> [(Int64, Text)] -> Maybe Int -> PlatformBackend
napcat calls members retcode =
  PlatformBackend
    { pbPlatform = "qq",
      pbName = "fixture",
      pbSend = \_ -> fail "unexpected platform send",
      pbCall = \action _ -> case action of
        GetGroupMemberList _ -> answer 0 (toJSON [object ["user_id" .= uid, "role" .= role, "nickname" .= role] | (uid, role) <- members])
        DeleteMsg target message -> record (Recall target message)
        SetGroupBan target user seconds -> record (Ban target user seconds)
        _ -> fail ("unexpected platform call: " <> show action)
    }
  where
    record call = modifyIORef' calls (<> [call]) >> answer (fromMaybe 0 retcode) Null
    answer code value = pure (Right (Response (if code == 0 then "ok" else "failed") code value "test"))
