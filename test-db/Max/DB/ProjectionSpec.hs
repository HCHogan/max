module Max.DB.ProjectionSpec (spec) where

import Control.Monad (forM_, void)
import Data.Text (Text)
import Data.Text qualified as T
import Database.PostgreSQL.Simple
import Helpers (truncateAll)
import Max.DB.Connection (DbPool, withConn)
import Max.DB.Projection
import Max.DB.TaskSpec (seed)
import Max.Platform.Types (CanonicalMessageId (..))
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "canonical projection verification" $ do
  it "preserves event tokens from relation evidence instead of erasing empty IR bodies" $ do
    (_, target, _) <- seed pool 900 1
    (_, message, _) <- seed pool 900 1
    let targetText = T.pack (show target.unCanonicalMessageId)
    withConn pool $ \connection -> do
      original <- projectionRows connection
      forM_ original $ \row -> expectedProjection connection row `shouldReturn` Right row.renderedText
      forM_ [("reaction","reaction",True,"[react#"<>targetText<>": 👍]"),
             ("reaction","reaction",False,"[unreact#"<>targetText<>": 👍]"),
             ("redaction","redacts",True,"[unsend#"<>targetText<>"]"),
             ("edit","replace",True,"[edit#"<>targetText<>"]")] $ \(event,relation,added,expected :: Text) -> do
        void $ execute connection "DELETE FROM message_relations WHERE canonical_message_id=?" (Only message.unCanonicalMessageId)
        void $ execute connection "UPDATE messages SET event_kind=?,canonical_content='{\"v\":2,\"nodes\":[]}',rendered_text=? WHERE canonical_message_id=?"
          (event :: Text,expected,message.unCanonicalMessageId)
        void $ execute connection "INSERT INTO message_relations(canonical_message_id,relation_kind,target_canonical_message_id,reaction_key,reaction_added) VALUES (?,?,?,'👍',?)"
          (message.unCanonicalMessageId,relation :: Text,target.unCanonicalMessageId,added)
        rows <- projectionRows connection
        forM_ rows $ \row -> expectedProjection connection row `shouldReturn` Right row.renderedText
        let selected = filter ((== message.unCanonicalMessageId) . (.canonicalMessageId)) rows
        length selected `shouldBe` 1
        forM_ selected $ \row -> do
          expectedProjection connection row `shouldReturn` Right expected
          expectedProjection connection (row {renderedText=""}) `shouldReturn` Right expected
