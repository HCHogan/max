{-# LANGUAGE TypeFamilies #-}

-- | Sandbox authority is bound to one group by the host. Tools never receive
-- the registry, host container names as authority, or an arbitrary IO callback.
module Max.Effects.Sandbox
  ( Sandbox,
    createSandbox,
    execInSandbox,
    searchPackages,
    listSandboxes,
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
  ( SandboxEntry (seContainer, seCreatedAt, seId, seImage),
    SandboxRegistry,
    createSandbox,
    defaultCreateOpts,
    destroySandbox,
    execInSandbox,
    listSandbox,
    listSandboxesForGroup,
    readSandboxFile,
    writeSandboxFile,
  )
import Max.Sandbox.Runtime qualified as Runtime (runSearch)
import Max.Sandbox.Types
  ( ExecResult,
    SandboxId,
    SandboxInfo (SandboxInfo),
  )
import OneBot.Types (GroupId)

data Sandbox :: Effect where
  Create :: Sandbox m (Either Text SandboxInfo)
  Execute :: SandboxId -> [Text] -> Text -> Int -> Sandbox m (Either Text ExecResult)
  Search :: SandboxId -> Text -> Sandbox m (Either Text Text)
  List :: Sandbox m [SandboxInfo]
  Destroy :: SandboxId -> Sandbox m (Either Text ())
  ReadFile :: SandboxId -> Text -> Int -> Sandbox m (Either Text Text)
  WriteFile :: SandboxId -> Text -> Text -> Sandbox m (Either Text ())

type instance DispatchOf Sandbox = Dynamic

createSandbox :: (Sandbox :> es) => Eff es (Either Text SandboxInfo)
createSandbox = send Create

execInSandbox :: (Sandbox :> es) => SandboxId -> [Text] -> Text -> Int -> Eff es (Either Text ExecResult)
execInSandbox sid packages command seconds = send (Execute sid packages command seconds)

searchPackages :: (Sandbox :> es) => SandboxId -> Text -> Eff es (Either Text Text)
searchPackages sid query = send (Search sid query)

listSandboxes :: (Sandbox :> es) => Eff es [SandboxInfo]
listSandboxes = send List

destroySandbox :: (Sandbox :> es) => SandboxId -> Eff es (Either Text ())
destroySandbox = send . Destroy

readSandboxFile :: (Sandbox :> es) => SandboxId -> Text -> Int -> Eff es (Either Text Text)
readSandboxFile sid path cap = send (ReadFile sid path cap)

writeSandboxFile :: (Sandbox :> es) => SandboxId -> Text -> Text -> Eff es (Either Text ())
writeSandboxFile sid path value = send (WriteFile sid path value)

runSandbox :: (IOE :> es) => GroupId -> Registry.SandboxRegistry -> Eff (Sandbox : es) a -> Eff es a
runSandbox group registry = interpret $ \_ operation -> liftIO $ case operation of
  Create -> fmap summary <$> Registry.createSandbox registry group Registry.defaultCreateOpts
  Execute sid packages command seconds -> Registry.execInSandbox registry group sid packages command seconds
  Search sid query ->
    Registry.listSandbox registry group sid >>= \case
      Nothing -> pure (Left "sandbox not found")
      Just entry -> Runtime.runSearch entry.seContainer query
  List -> map summary <$> Registry.listSandboxesForGroup registry group
  Destroy sid -> Registry.destroySandbox registry group sid
  ReadFile sid path cap -> Registry.readSandboxFile registry group sid path cap
  WriteFile sid path value -> Registry.writeSandboxFile registry group sid path value
  where
    summary entry = SandboxInfo entry.seId entry.seImage entry.seContainer entry.seCreatedAt
