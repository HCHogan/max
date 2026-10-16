module Max.ResourceCapabilitiesSpec (spec) where

import Control.Monad (forM_, void)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple.Types (Only (..))
import Effectful.PostgreSQL (execute, query)
import Helpers (truncateAll, withDb)
import JobFixture (seed)
import Max.Conversation.Roster
  ( ConversationRoster (..),
    RosterIdentity (..),
  )
import Max.ConversationScope (conversationScopeFor)
import Max.DB.Connection (DbPool)
import Max.DB.Files qualified as Files
import Max.DB.Media qualified as MediaDB
import Max.DB.Session qualified as SessionDB
import Max.DB.Transaction (withTransaction)
import Max.Effects.ConversationQuery qualified as Conversation
import Max.Effects.MediaQuery qualified as Media
import Max.Effects.StickerQuery qualified as Sticker
import Max.Embedding (EmbeddingRecord (..))
import Max.File.Types (FileRecord (..))
import Max.Media.Types (StoredImage (..), StoredVideo (..))
import Max.Platform.Store.Identity
  ( ensureEndpointPrincipals,
    resolveMentionIdentities,
  )
import Max.Platform.Types (CanonicalMessageId (..), EndpointId (..), NativeUserId (..))
import Max.Session qualified as Session
import Max.Session.Types (Session (..))
import OneBot.Types (GroupId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "scoped resource capabilities" $ do
  it "confines media, file catalog and roster reads to the host conversation" $ do
    (_, CanonicalMessageId identifier, actor) <- seed pool 900 1
    (_, _, otherActor) <- seed pool 901 2
    let scope = conversationScopeFor (GroupId 900)
        foreignScope = conversationScopeFor (GroupId 901)
    void $ withDb pool (execute "INSERT INTO images(sha256,mime_type,bytes_size,local_path) VALUES('asset-image','image/png',3,'private')" ())
    void $ withDb pool (execute "INSERT INTO message_images(canonical_message_id,sha256,seg_index) VALUES(?,'asset-image',0)" [identifier])
    void $ withDb pool (execute "INSERT INTO videos(sha256,mime_type,bytes_size,local_path) VALUES('asset-video','video/mp4',3,'private')" ())
    void $ withDb pool (execute "INSERT INTO message_videos(canonical_message_id,sha256,seg_index) VALUES(?,'asset-video',1)" [identifier])
    (message, images) <- withDb pool (Media.runMediaQuery scope (Media.readImages identifier Nothing))
    message `shouldSatisfy` isJust
    map (.storedImageSha256) images `shouldBe` ["asset-image"]
    (outside, outsideImages) <- withDb pool (Media.runMediaQuery foreignScope (Media.readImages identifier Nothing))
    outside `shouldSatisfy` isNothing
    outsideImages `shouldSatisfy` null
    video <- withDb pool (Media.runMediaQuery scope (Media.readVideo identifier (Just 1)))
    fmap (.storedVideoSha256) video `shouldBe` Just "asset-video"
    withDb pool (Media.runMediaQuery foreignScope (Media.readVideo identifier Nothing)) >>= (`shouldSatisfy` isNothing)
    forM_ [1 .. 55 :: Int] $ \index ->
      withDb pool (Files.insertSeen (T.pack (show index)) 900 (Just identifier) 1 "file.txt" Nothing)
    -- Sandbox views read this conversation's catalog only.
    files <- withDb pool (Files.listConversationFilesInScope scope)
    length files `shouldBe` 55
    map (.frGroupId) files `shouldBe` replicate 55 900
    withDb pool (Files.listConversationFilesInScope foreignScope) >>= (`shouldSatisfy` null)
    map (.cmrSha256) <$> withDb pool (MediaDB.fetchConversationImagesInScope scope) `shouldReturn` ["asset-image"]
    withDb pool (MediaDB.fetchConversationImagesInScope foreignScope) >>= (`shouldSatisfy` null)
    withDb pool (MediaDB.fetchConversationVideosInScope foreignScope) >>= (`shouldSatisfy` null)
    roster <- withDb pool (Conversation.runConversationQuery scope Conversation.readRoster)
    map (.riPrincipalId) roster.crIdentities `shouldContain` [actor]
    map (.riPrincipalId) roster.crIdentities `shouldNotContain` [otherActor]

  it "rejects foreign mentions on a shared account and remembers a contentless poke locally" $ do
    (_, CanonicalMessageId message, _) <- seed pool 900 1
    (_, _, outsider) <- seed pool 901 2
    withDb pool (resolveMentionIdentities 900 [outsider]) `shouldReturn` Map.empty
    [Only endpoint] <- withDb pool (query "SELECT origin_endpoint_id FROM messages WHERE canonical_message_id=?" (Only message))
    identities <- withDb pool (ensureEndpointPrincipals (EndpointId endpoint) (Map.singleton (NativeUserId "poke-only") (Just "poke participant")))
    Just participant <- pure (Map.lookup (NativeUserId "poke-only") identities)
    resolved <- withDb pool (resolveMentionIdentities 900 [participant])
    Map.member participant resolved `shouldBe` True
    withDb pool (resolveMentionIdentities 901 [participant]) `shouldReturn` Map.empty
    roster <- withDb pool (Conversation.runConversationQuery (conversationScopeFor (GroupId 900)) Conversation.readRoster)
    map (.riPrincipalId) roster.crIdentities `shouldContain` [participant]
    withDb pool (query "SELECT count(*) FROM messages" ()) `shouldReturn` [Only (2 :: Int)]

  it "searches only unbanned stickers in the requested embedding space and caps results" $ do
    forM_ (map (T.pack . show) [1 .. 9 :: Int] <> ["banned", "other", "wide", "far"]) $ \sha ->
      void $ withDb pool (execute "INSERT INTO images(sha256,mime_type,bytes_size,local_path) VALUES(?,'image/png',3,'unused')" (Only sha))
    forM_ [1 .. 9 :: Int] $ \index ->
      void $ withDb pool (execute "INSERT INTO stickers(sha256,kind,description,embedding,embedding_model,embedding_dimensions,embedding_content_hash,embedding_updated_at) VALUES(?,'custom',?,'[1,0]','space-a',2,repeat('a',64),now())" (T.pack (show index), "visible" :: Text))
    void $ withDb pool (execute "INSERT INTO stickers(sha256,kind,description,embedding,embedding_model,embedding_dimensions,banned,embedding_content_hash,embedding_updated_at) SELECT sha,'custom','hidden',embedding::vector,model,dimensions,banned,repeat('a',64),now() FROM (VALUES ('banned','[1,0]','space-a',2,true),('other','[1,0]','space-b',2,false),('wide','[1,0,0]','space-a',3,false),('far','[-1,0]','space-a',2,false)) candidate(sha,embedding,model,dimensions,banned)" ())
    let record = EmbeddingRecord "space-a" 2 "query-hash" "[1,0]"
    rows <- withDb pool (Sticker.runStickerQuery (Sticker.searchStickers record))
    length rows `shouldBe` 6
    map snd rows `shouldBe` replicate 6 "visible"

  it "rejects nested cache mutations before they can escape an outer rollback" $ do
    sessions <- Session.newSessionRegistry
    handle <- withDb pool (Session.loadSession sessions "test" (GroupId 900))
    withDb pool (withTransaction (Session.updateSession handle (\current -> (current {persona = Just "nested"}, ())))) `shouldThrow` anyException
    state <- Session.readSession handle
    state.persona `shouldBe` Nothing
    persisted <- withDb pool (SessionDB.fetchOrInit (GroupId 900) "test")
    persisted.persona `shouldBe` Nothing
