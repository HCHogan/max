{-# LANGUAGE TypeFamilies #-}

module Max.Effects.FileTransfer (FileTransfer, importGroupFile, sendSandboxImage, sendSandboxFile, runFileTransfer) where

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
  ImportGroupFile :: Text -> Text -> Maybe Text -> FileTransfer m (Either Text Value)
  SendSandboxImage :: Text -> Text -> Maybe Text -> FileTransfer m (Either Text Value)
  SendSandboxFile :: Text -> Text -> Maybe Text -> FileTransfer m (Either Text Value)

type instance DispatchOf FileTransfer = Dynamic

importGroupFile :: (FileTransfer :> es) => Text -> Text -> Maybe Text -> Eff es (Either Text Value)
importGroupFile file sandbox destination = send (ImportGroupFile file sandbox destination)

sendSandboxImage :: (FileTransfer :> es) => Text -> Text -> Maybe Text -> Eff es (Either Text Value)
sendSandboxImage sandbox path caption = send (SendSandboxImage sandbox path caption)

sendSandboxFile :: (FileTransfer :> es) => Text -> Text -> Maybe Text -> Eff es (Either Text Value)
sendSandboxFile sandbox path name = send (SendSandboxFile sandbox path name)

runFileTransfer ::
  (Text -> Text -> Maybe Text -> Eff es (Either Text Value)) ->
  (Text -> Text -> Maybe Text -> Eff es (Either Text Value)) ->
  (Text -> Text -> Maybe Text -> Eff es (Either Text Value)) ->
  Eff (FileTransfer : es) a ->
  Eff es a
runFileTransfer copy image file = interpret $ \_ -> \case
  ImportGroupFile source sandbox destination -> copy source sandbox destination
  SendSandboxImage sandbox path caption -> image sandbox path caption
  SendSandboxFile sandbox path name -> file sandbox path name
