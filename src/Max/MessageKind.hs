module Max.MessageKind
  ( MessageKind (..),
    renderMessageKind,
  )
where

import Data.Text (Text)
import Database.PostgreSQL.Simple.ToField (ToField (..))

-- | Transcript visibility class. Every message remains in the canonical
-- ledger; prompt readers select only 'KindChat'.
data MessageKind
  = KindChat
  | KindCommand
  | KindDebug
  deriving stock (Show, Eq)

instance ToField MessageKind where
  toField = toField . renderMessageKind

renderMessageKind :: MessageKind -> Text
renderMessageKind = \case
  KindChat -> "chat"
  KindCommand -> "command"
  KindDebug -> "debug"
