{-# LANGUAGE TypeFamilies #-}

-- | Name a stored object in its conversation's sandbox view. Ingest supplies
-- the /chat name and a content reference; only the interpreter knows where
-- objects and views live on the host.
module Max.Effects.ChatView (ChatView, linkChatMedia, runChatViewWith) where

import Data.Text (Text)
import Effectful
  ( Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    type (:>),
  )
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Blob.Reference (BlobRef)
import OneBot.Types (GroupId)

data ChatView :: Effect where
  LinkChatMedia :: GroupId -> Text -> BlobRef -> ChatView m ()

type instance DispatchOf ChatView = Dynamic

linkChatMedia :: (ChatView :> es) => GroupId -> Text -> BlobRef -> Eff es ()
linkChatMedia group name ref = send (LinkChatMedia group name ref)

runChatViewWith :: (GroupId -> Text -> BlobRef -> Eff es ()) -> Eff (ChatView : es) a -> Eff es a
runChatViewWith link = interpret $ \_ -> \case
  LinkChatMedia group name ref -> link group name ref
