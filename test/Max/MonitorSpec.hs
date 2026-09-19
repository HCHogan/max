module Max.MonitorSpec (spec) where

import Data.Map.Strict qualified as Map
import Max.IR (Body (..), MentionTarget (..), Node (..))
import Max.Monitor.Types
  ( LedgerMatchSpec (..),
    MonitorOrdinal (..),
    ledgerMatchSpecValue,
    ledgerSpecMatches,
    monitorHandleText,
    parseLedgerMatchSpec,
    parseMonitorHandle,
  )
import Max.Platform.Types (PrincipalId (..), PrincipalIdentityId (..))
import Test.Hspec

spec :: Spec
spec = do
  describe "monitor handles" $ do
    it "round-trips the scoped m# grammar" $ do
      monitorHandleText (MonitorOrdinal 12) `shouldBe` "m#12"
      parseMonitorHandle " m#12 " `shouldBe` Just (MonitorOrdinal 12)

    it "rejects bare ids and non-positive ordinals" $ do
      parseMonitorHandle "12" `shouldBe` Nothing
      parseMonitorHandle "m#0" `shouldBe` Nothing
      parseMonitorHandle "m#-1" `shouldBe` Nothing

  describe "LedgerMatch typed predicates" $ do
    it "round-trips the versioned spec and combines predicates without executable code" $ do
      let sender = PrincipalId 7
          self = PrincipalId 99
          selfIdentity = PrincipalIdentityId 12
          spec' = LedgerMatchSpec (Just sender) (Just "release READY") Nothing True
          body = Body [NText "Release ready", NMention (MentionIdentity selfIdentity) "max"]
      parseLedgerMatchSpec (ledgerMatchSpecValue spec') `shouldBe` Right spec'
      ledgerSpecMatches spec' sender self (Map.singleton selfIdentity self) "The RELEASE ready now" body
        `shouldBe` True
      ledgerSpecMatches spec' (PrincipalId 8) self (Map.singleton selfIdentity self) "The RELEASE ready now" body
        `shouldBe` False

    it "never lets Max's own utterance retrigger Max's own watcher" $ do
      let self = PrincipalId 99
          watchAnyone = LedgerMatchSpec Nothing (Just "launch") Nothing False
          watchSelf = LedgerMatchSpec (Just self) (Just "launch") Nothing False
          body = Body [NText "launch is ready"]
      ledgerSpecMatches watchAnyone (PrincipalId 7) self Map.empty "launch is ready" body
        `shouldBe` True
      -- An unreconciled self-event is an ordinary live inbound row, and an
      -- elaborated continuation speaks: both spellings must stay closed.
      ledgerSpecMatches watchAnyone self self Map.empty "launch is ready" body
        `shouldBe` False
      ledgerSpecMatches watchSelf self self Map.empty "launch is ready" body
        `shouldBe` False

    it "rejects an empty condition rather than creating an always-on watcher" $ do
      let empty = LedgerMatchSpec Nothing Nothing Nothing False
      parseLedgerMatchSpec (ledgerMatchSpecValue empty)
        `shouldBe` Left "LedgerMatch requires at least one predicate"
