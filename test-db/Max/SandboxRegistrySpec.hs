module Max.SandboxRegistrySpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently, wait, withAsync)
import Control.Exception (bracket)
import Control.Monad (unless, void)
import Data.Either (fromLeft)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text qualified as T
import Database.PostgreSQL.Simple (Only (..), execute_, query_)
import Helpers (insertRawMessage, testTime, truncateAll)
import Max.DB.Connection (DbPool, withConn)
import Max.Runtime.Protocol (sandboxPolicyVersion)
import Max.Sandbox.Registry
import Max.Sandbox.Runtime (ExecResult (..))
import OneBot.Types (GroupId (..))
import System.Directory
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Hspec

spec :: DbPool -> Spec
spec pool = before_ (truncateAll pool) $ describe "concurrent sandbox registry" $ do
  it "overlaps commands, retains distinct outputs and waits before destroying the shared sandbox" $
    fixture pool $ \registry directory -> do
      let path file = "\"" <> (directory </> file) <> "\""
          run label =
            execInSandbox
              registry
              (GroupId 42)
              (SandboxId "s1")
              []
              (T.pack ("touch " <> path label <> "; while ! test -f " <> path "release" <> "; do sleep 0.01; done; printf " <> label))
              10
          await path = timeout 3000000 (waitForFile path) `shouldReturn` Just ()
      withAsync (run "first") $ \first -> withAsync (run "second") $ \second -> do
        await (directory </> "first")
        await (directory </> "second")
        -- Other conversations still cannot obtain this group's sandbox.
        missing <- execInSandbox registry (GroupId 43) (SandboxId "s1") [] "false" 1
        fromLeft "unexpected execution" missing `shouldBe` "sandbox not found"
        withAsync (destroySandbox registry (GroupId 42) (SandboxId "s1")) $ \destroy -> do
          timeout 50000 (wait destroy) `shouldReturn` Nothing
          writeFile (directory </> "release") "go"
          left <- wait first
          right <- wait second
          fmap (.erStdout) left `shouldBe` Right "first"
          fmap (.erStdout) right `shouldBe` Right "second"
          wait destroy `shouldReturn` Right ()
          later <- execInSandbox registry (GroupId 42) (SandboxId "s1") [] "false" 1
          fromLeft "unexpected execution" later `shouldBe` "sandbox not found"

  it "starts one sandbox when a group's first calls arrive together, then backfills its view" $ do
    backfilled <- newIORef []
    fixtureWith pool (\group -> atomicModifyIORef' backfilled (\groups -> (group : groups, ()))) $ \registry _ -> do
      void $ insertRawMessage pool 2 43 100 999 testTime Nothing "first use"
      (first, second) <- concurrently (ensureSandbox registry (GroupId 43)) (ensureSandbox registry (GroupId 43))
      fmap (.seId) first `shouldBe` fmap (.seId) second
      fmap (.seId) first `shouldSatisfy` either (const False) (const True)
      started <- withConn pool $ \connection ->
        query_ connection "SELECT count(*) FROM sandboxes JOIN conversations USING (conversation_id) WHERE legacy_group_id = 43"
      started `shouldBe` [Only (1 :: Int)]
      -- The broker created the view with the sandbox; existing media follow.
      readIORef backfilled `shouldReturn` [GroupId 43]

waitForFile :: FilePath -> IO ()
waitForFile path = do
  exists <- doesFileExist path
  unless exists (threadDelay 10000 >> waitForFile path)

-- Exercise real registry/DB admission with a process fixture at the broker boundary.
-- The Linux VM check separately exercises nspawn and systemd cancellation.
fixture :: DbPool -> (SandboxRegistry -> FilePath -> IO a) -> IO a
fixture pool = fixtureWith pool (const (pure ()))

fixtureWith :: DbPool -> ChatViewBackfill -> (SandboxRegistry -> FilePath -> IO a) -> IO a
fixtureWith pool backfill action = withSystemTempDirectory "max-shared-sandbox" $ \directory -> do
  void $ insertRawMessage pool 1 42 100 999 testTime Nothing "sandbox fixture"
  withConn pool $ \connection ->
    void $
      execute_
        connection
        "INSERT INTO sandboxes(conversation_id,sandbox_handle,container_name,volume_name,image,network_mode,status,expires_at) SELECT conversation_id,'s1','max-sb-42-s1','max-sb-42-s1-data','nixos-sandbox-v1','max-sandbox','active',now()+interval '14 days' FROM conversations WHERE legacy_group_id=42"
  let command = directory </> "max-runtime"
  writeFile command $
    unlines
      [ "#!/bin/sh",
        "case \"$1\" in",
        " list) echo max-sb-42-s1;;",
        -- Starting is slow enough that unserialized first uses would both start.
        " create) sleep 0.3; echo \"$2\";;",
        " volumes) echo max-sb-42-s1-data;;",
        " status) echo running;;",
        " policy) echo '" <> T.unpack sandboxPolicyVersion <> " max-sandbox 1';;",
        " network) echo max-sandbox;;",
        " volume-status) test ! -f '" <> (directory </> "removed") <> "' || exit 3;;",
        " volume-remove) touch '" <> (directory </> "removed") <> "';;",
        " remove) exit 0;;",
        " exec)",
        "  shift; if test \"$1\" = --workdir; then shift 2; fi; shift",
        "  case \"$*\" in *max-observe-*) exit 0;; esac",
        "  exec \"$@\";;",
        " *) exit 64;;",
        "esac"
      ]
  permissions <- getPermissions command
  setPermissions command (permissions {executable = True})
  bracket (lookupEnv "PATH") (maybe (unsetEnv "PATH") (setEnv "PATH")) $ \previous -> do
    setEnv "PATH" (directory <> maybe "" (':' :) previous)
    registry <- newDurableSandboxRegistry pool backfill
    action registry directory
