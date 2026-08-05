module Max.MessageKind
  ( MessageKind (..),
    renderMessageKind,
  )
where

import Data.Text (Text)
import Database.PostgreSQL.Simple.ToField (ToField (..))

-- | Transcript visibility class.  Every message remains in the canonical
-- ledger; this decides who is allowed to read it back.
--
-- The cut is "would a member of the room have seen this", not "what kind of
-- platform event was it" — @event_kind@ already answers the second question,
-- and answering it twice is how the two drift apart.
data MessageKind
  = -- | Something somebody said.  The transcript.
    KindChat
  | -- | Addressed to max as an operator interface, not to the room.
    KindCommand
  | -- | The room watched this happen but nobody said it: a 撤回, a 贴表情.
    -- Model-visible so max is not the only participant who missed it, and
    -- never a trigger — noticing is not the same as being spoken to.
    KindSystem
  | -- | Nobody saw it.  Tool traces, unparseable payloads, max's own
    -- internal markers.  The model never reads these.
    KindDebug
  deriving stock (Show, Eq)

instance ToField MessageKind where
  toField = toField . renderMessageKind

renderMessageKind :: MessageKind -> Text
renderMessageKind = \case
  KindChat -> "chat"
  KindCommand -> "command"
  KindSystem -> "system"
  KindDebug -> "debug"
