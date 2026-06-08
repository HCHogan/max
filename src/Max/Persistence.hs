-- |
-- Per-dispatch "is this turn allowed to mutate persisted state?"
-- flag, carried through the effect stack as a 'Reader'.
--
-- The 'Persistent' mode is the default everywhere — outbound replies
-- land in the @messages@ table, btw notes get drained off the
-- session, sayTool persists its status updates.
--
-- 'Ephemeral' mode is set by 'withEphemeral' for the duration of a
-- subcomputation.  Inside that scope, persistence writes are
-- suppressed (the reply still goes out over NapCat — that's a real
-- side effect we can't undo — but the messages-table write and any
-- session-state mutations don't happen).  This is what powers the
-- new !btw semantics: ask a one-off question using the current
-- context without polluting the bot's memory of the conversation.
--
-- We use 'Effectful.Reader.Dynamic' specifically (rather than
-- 'Effectful.Reader.Static') because 'local' on the dynamic Reader
-- is a proper higher-order scoping operation — exactly what we want
-- here, and the closest effectful gets to a custom HO effect
-- without 'unsafeEff'.
module Max.Persistence
  ( PersistMode (..),
    isEphemeral,
    withEphemeral,
  )
where

import Effectful (Eff, (:>))
import Effectful.Reader.Dynamic (Reader, ask, local)

-- | Whether persistence writes should fire in the current scope.
--
-- The constructors are deliberately prefixed (rather than the obvious
-- @Persistent@ / @Ephemeral@) because both bare names collide with
-- 'Effectful.Persistence' constructors exported by the @Effectful@
-- prelude.
data PersistMode
  = -- | Normal dispatch: insertOutbound runs, session updates persist.
    Persisted
  | -- | Scoped suppression set by 'withEphemeral': the reply still
    -- gets sent over NapCat, but it isn't written to the messages
    -- table and any 'updateSession' calls within the scope are
    -- skipped.  Caller stays oblivious — gating happens at the
    -- persistence touchpoints.
    Volatile
  deriving (Eq, Show)

-- | True when we're inside a 'withEphemeral' scope.  Consult this
-- right before any 'insertOutbound' / 'updateSession' call.
isEphemeral :: Reader PersistMode :> es => Eff es Bool
isEphemeral = (== Volatile) <$> ask

-- | Scope an action under 'Volatile' mode.  Calls to 'isEphemeral'
-- anywhere in the dynamic extent of the argument return 'True',
-- regardless of what the surrounding scope set.  Restores on exit.
withEphemeral :: Reader PersistMode :> es => Eff es a -> Eff es a
withEphemeral = local (const Volatile)
