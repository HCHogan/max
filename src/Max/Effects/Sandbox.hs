{-# LANGUAGE TypeFamilies #-}

-- | Sandbox authority is bound to one group by the host. Every operation uses
-- that group's sandbox, started on first use; tools never receive the
-- registry, host container names as authority, or an arbitrary IO callback.
module Max.Effects.Sandbox
  ( Sandbox,
    execInSandbox,
    searchPackages,
    destroySandbox,
    readSandboxFile,
    writeSandboxFile,
    runSandbox,
  )
where

import Data.Text (Text)
import Effectful
  ( Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    IOE,
    MonadIO (liftIO),
    type (:>),
  )
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Sandbox.Registry qualified as Registry
  ( SandboxEntry (seContainer, seId),
    SandboxRegistry,
    destroySandboxesForGroup,
    ensureSandbox,
    execInSandbox,
    readSandboxFile,
    writeSandboxFile,
  )
import Max.Sandbox.Runtime qualified as Runtime (runSearch)
import Max.Sandbox.Types (ExecResult, SandboxRead)
import OneBot.Types (GroupId)

data Sandbox :: Effect where
  Execute :: [Text] -> Text -> Int -> Sandbox m (Either Text ExecResult)
  Search :: Text -> Sandbox m (Either Text Text)
  Destroy :: Sandbox m Int
  ReadFile :: Text -> Int -> Sandbox m (Either Text SandboxRead)
  WriteFile :: Text -> Text -> Sandbox m (Either Text ())

type instance DispatchOf Sandbox = Dynamic

execInSandbox :: (Sandbox :> es) => [Text] -> Text -> Int -> Eff es (Either Text ExecResult)
execInSandbox packages command seconds = send (Execute packages command seconds)

searchPackages :: (Sandbox :> es) => Text -> Eff es (Either Text Text)
searchPackages = send . Search

-- | Remove the group's sandbox and its /work; the next use starts fresh.
destroySandbox :: (Sandbox :> es) => Eff es Int
destroySandbox = send Destroy

readSandboxFile :: (Sandbox :> es) => Text -> Int -> Eff es (Either Text SandboxRead)
readSandboxFile path cap = send (ReadFile path cap)

writeSandboxFile :: (Sandbox :> es) => Text -> Text -> Eff es (Either Text ())
writeSandboxFile path value = send (WriteFile path value)

runSandbox :: (IOE :> es) => GroupId -> Registry.SandboxRegistry -> Eff (Sandbox : es) a -> Eff es a
runSandbox group registry = interpret $ \_ operation -> liftIO $ case operation of
  Execute packages command seconds -> withSandbox $ \entry -> Registry.execInSandbox registry group entry.seId packages command seconds
  Search query -> withSandbox $ \entry -> Runtime.runSearch entry.seContainer query
  Destroy -> Registry.destroySandboxesForGroup registry group
  ReadFile path cap -> withSandbox $ \entry -> Registry.readSandboxFile registry group entry.seId path cap
  WriteFile path value -> withSandbox $ \entry -> Registry.writeSandboxFile registry group entry.seId path value
  where
    withSandbox :: (Registry.SandboxEntry -> IO (Either Text b)) -> IO (Either Text b)
    withSandbox action = Registry.ensureSandbox registry group >>= either (pure . Left) action
