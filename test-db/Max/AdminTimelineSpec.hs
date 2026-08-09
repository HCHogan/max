module Max.AdminTimelineSpec (spec) where

import Control.Concurrent.Async (async, wait)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Int (Int64)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time (UTCTime, getCurrentTime)
import Database.PostgreSQL.Simple (Only (..), execute, query)
import Helpers (resultId, truncateAll, withDb)
import Max.AdminTimeline (loadAdminTimeline, waitAdminTimeline)
import Max.DB.Connection (DbPool, withConn)
import Max.IR
import Max.IR.Lower (textOnlyCaps)
import Max.Platform.Envelope (InboundEnvelope (..), IngestClass (LiveDelivery))
import Max.Platform.Store
import Max.Platform.Types
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "Max.AdminTimeline" $ do
  it "tails conversation_seq through the commit-safe LISTEN/NOTIFY path" $ do
    endpoint <-
      withDb pool $
        ensureConfiguredEndpoint
          PlatformMatrix
          (NativeAccountId "@max:live.test")
          (NativeConversationId "!room:live.test")
          ConversationGroup
          EndpointStandalone
          (Just 43)
          textOnlyCaps
    revision <- currentRevision pool 43
    waiter <- async (withDb pool (waitAdminTimeline 43 0 revision))
    now <- getCurrentTime
    _ <- withDb pool (ingestEnvelope defaultIngestOptions (baseEnvelope endpoint.endpointId now "live"))
    wait waiter `shouldReturn` True
    timeline <- withDb pool (loadAdminTimeline 43 (Just 0) 10)
    timeline `shouldSatisfy` isJust

  it "wakes for delivery-state changes that do not advance conversation_seq" $ do
    endpoint <-
      withDb pool $
        ensureConfiguredEndpoint
          PlatformMatrix
          (NativeAccountId "@max:delivery-live.test")
          (NativeConversationId "!room:delivery-live.test")
          ConversationGroup
          EndpointStandalone
          (Just 44)
          textOnlyCaps
    now <- getCurrentTime
    message <- withDb pool (ingestEnvelope defaultIngestOptions (baseEnvelope endpoint.endpointId now "delivery-live"))
    [(latest, revision)] <- withConn pool $ \conn ->
      query
        conn
        "SELECT message.conversation_seq, timeline.revision \
        \ FROM messages message \
        \ JOIN admin_timeline_revisions timeline USING (conversation_id) \
        \ WHERE message.canonical_message_id = ?"
        (Only (resultId message).unCanonicalMessageId)
    waiter <- async (withDb pool (waitAdminTimeline 44 latest revision))
    _ <- withConn pool $ \conn ->
      execute
        conn
        "UPDATE message_deliveries SET updated_at = now() WHERE canonical_message_id = ?"
        (Only (resultId message).unCanonicalMessageId)
    wait waiter `shouldReturn` True

  it "hydrates identities, authenticated blobs, forward children, raw unsupported data, and delivery audit" $ do
    endpoint <-
      withDb pool $
        ensureConfiguredEndpoint
          PlatformMatrix
          (NativeAccountId "@max:example.test")
          (NativeConversationId "!room:example.test")
          ConversationGroup
          EndpointStandalone
          (Just 42)
          textOnlyCaps
    now <- getCurrentTime
    let sha = T.replicate 64 "a"
        media = fromMaybe (error "valid blob fixture") (mediaBlobRef sha)
        parentEnvelope =
          (baseEnvelope endpoint.endpointId now "parent")
            { content =
                Body
                  [ NMention (NativeUserId "@alice:example.test") "Alice",
                    NText " sent ",
                    NMedia
                      (Just media)
                      MediaMeta
                        { kind = MImage,
                          mime = Just "image/png",
                          sizeBytes = Just 12,
                          name = Just "proof.png",
                          description = Just "proof",
                          raw = Nothing
                        },
                    NForward (ForwardRef "bundle" (Just 1)),
                    NUnsupported (Unsupported "matrix:custom" "custom event" (Just (object ["x" .= (1 :: Int)])))
                  ]
            }
    parent <- withDb pool (ingestEnvelope defaultIngestOptions parentEnvelope)
    child <-
      withDb pool $
        ingestEnvelope
          defaultIngestOptions
            { createDispatch = False,
              createMirrorDeliveries = False
            }
          ( (baseEnvelope endpoint.endpointId now "child")
              { content = Body [NText "inside"],
                relations = [ContainedIn (NativeEventId "parent") 0]
              }
          )
    timeline <- withDb pool (loadAdminTimeline 42 Nothing 10)
    let rendered = maybe "" (TE.decodeUtf8 . LBS.toStrict . encode) timeline
        parentId = T.pack (show (resultId parent).unCanonicalMessageId)
        childId = T.pack (show (resultId child).unCanonicalMessageId)
    rendered `shouldSatisfy` T.isInfixOf parentId
    rendered `shouldSatisfy` T.isInfixOf childId
    rendered `shouldSatisfy` T.isInfixOf ("/api/blobs/" <> sha)
    rendered `shouldSatisfy` T.isInfixOf "@alice:example.test"
    rendered `shouldSatisfy` T.isInfixOf "matrix:custom"
    rendered `shouldSatisfy` T.isInfixOf "lower_notes"
    rendered `shouldSatisfy` T.isInfixOf "capabilities"
    rendered `shouldSatisfy` T.isInfixOf "work_summary"
    rendered `shouldSatisfy` T.isInfixOf "media_parked_global"

baseEnvelope :: EndpointId -> UTCTime -> Text -> InboundEnvelope
baseEnvelope endpoint now native =
  InboundEnvelope
    { endpointId = endpoint,
      nativeEventId = NativeEventId native,
      senderNativeId = NativeUserId "@bob:example.test",
      senderDisplayName = Just "Bob",
      occurredAt = now,
      receivedAt = now,
      eventKind = EventMessage,
      ingestClass = LiveDelivery,
      content = Body [],
      relations = [],
      sourceCursor = Nothing,
      rawPayload = Nothing
    }

currentRevision :: DbPool -> Int64 -> IO Int64
currentRevision pool legacyConversation = do
  rows <- withConn pool $ \conn ->
    query
      conn
      "SELECT COALESCE(timeline.revision, 0) \
      \ FROM conversations conversation \
      \ LEFT JOIN admin_timeline_revisions timeline USING (conversation_id) \
      \ WHERE conversation.legacy_group_id = ?"
      (Only legacyConversation)
  case rows of
    [Only revision] -> pure revision
    _ -> expectationFailure "missing timeline revision" >> fail "unreachable"
