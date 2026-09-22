{-# LANGUAGE TypeFamilies #-}

-- | Publish a file from the conversation's sandbox. Paths are sandbox paths;
-- the host chooses the sandbox and reads the bytes once.
module Max.Effects.FileTransfer (FileTransfer, sendSandboxImage, sendSandboxFile, runFileTransfer) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful
  ( Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    type (:>),
  )
import Effectful.Dispatch.Dynamic (interpret, send)

data FileTransfer :: Effect where
  SendSandboxImage :: Text -> Maybe Text -> FileTransfer m (Either Text Value)
  SendSandboxFile :: Text -> Maybe Text -> FileTransfer m (Either Text Value)

type instance DispatchOf FileTransfer = Dynamic

sendSandboxImage :: (FileTransfer :> es) => Text -> Maybe Text -> Eff es (Either Text Value)
sendSandboxImage path caption = send (SendSandboxImage path caption)

sendSandboxFile :: (FileTransfer :> es) => Text -> Maybe Text -> Eff es (Either Text Value)
sendSandboxFile path name = send (SendSandboxFile path name)

runFileTransfer ::
  (Text -> Maybe Text -> Eff es (Either Text Value)) ->
  (Text -> Maybe Text -> Eff es (Either Text Value)) ->
  Eff (FileTransfer : es) a ->
  Eff es a
runFileTransfer image file = interpret $ \_ -> \case
  SendSandboxImage path caption -> image path caption
  SendSandboxFile path name -> file path name
