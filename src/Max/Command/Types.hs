-- |
-- AST for the @!@-prefixed command DSL.  Parsing happens in
-- "Max.Command.Parser"; per-command behaviour in "Max.Command.Dispatcher".
--
-- == Grammar
--
-- > command  ::= '!' ident (whitespace+ arg)*
-- > arg      ::= flag | value
-- > flag     ::= '--' ident ('=' value)?
-- > value    ::= barestring | "..." | '...'
-- > ident    ::= [a-zA-Z][a-zA-Z0-9-]*
--
-- Quoted strings ('"') support C-style escapes (@\\n@, @\\t@, @\\"@,
-- @\\\\@).  Single-quoted strings are literal — useful for things
-- already containing backslashes.
module Max.Command.Types
  ( Command (..),
    UnpinTarget (..),
    RawArgs (..),
    PosArg,
    Flag,
  )
where

import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)

-- | What @!unpin@ should target.
data UnpinTarget
  = UnpinOne !Int64 -- ^ '!unpin <id>'
  | UnpinReply -- ^ '!unpin' (no arg) — uses the SegReply on the trigger
  | UnpinAll -- ^ '!unpin all'
  deriving stock (Show, Eq)

-- | A parsed and structured command.  Unknown commands are represented
-- by 'Unknown' so the dispatcher can give a friendly "did you mean"
-- reply.
data Command
  = Help (Maybe Text) -- ^ '!help' or '!help <topic>'
  | ModelShow -- ^ '!model'
  | ModelList -- ^ '!model list'
  | ModelSet !Text -- ^ '!model <name>'
  | ModelThinkShow -- ^ '!model think'
  | ModelThinkSet !Bool -- ^ '!model think on' / '!model think off'
  | DebugShow -- ^ '!debug'
  | DebugSet !(Maybe Bool) -- ^ '!debug on' / '!debug off' / '!debug default'
  | PersonaShow -- ^ '!persona'
  | PersonaClear -- ^ '!persona clear'
  | PersonaSet !Text -- ^ '!persona <text>'
  | Clear -- ^ '!clear'
  | ClearAll -- ^ '!clear --all'
  | Unclear -- ^ '!unclear' — remove the cleared_at watermark
  | Pin !(Maybe Int64) -- ^ '!pin [id]' — Nothing = use reply target
  | Unpin !UnpinTarget -- ^ '!unpin [id|all]'
  | Pins -- ^ '!pins'
  | Btw !Text -- ^ '!btw <text>'
  | PsLocal -- ^ '!ps' (this group)
  | PsAll -- ^ '!ps --all'
  | Kill !Text -- ^ '!kill <id>'
  | BranchList -- ^ '!branch' or '!branch list'
  | BranchNew !Text -- ^ '!branch <name>' — fork from current + switch
  | BranchDelete !Text -- ^ '!branch delete <name>'
  | Switch !Text -- ^ '!switch <name>'
  | Unknown !Text !RawArgs -- ^ verb + raw args; parser succeeded but verb unknown
  deriving stock (Show, Eq)

-- | Positional argument after the verb.
type PosArg = Text

-- | One @--name@ or @--name=value@ flag.  A bare @--name@ stores
-- 'Nothing'; @--name=v@ stores 'Just v'.
type Flag = (Text, Maybe Text)

-- | Tokens after the verb, before command-specific interpretation.
-- The dispatcher unpacks these into the concrete 'Command' variants.
data RawArgs = RawArgs
  { positional :: ![PosArg],
    flags :: !(Map Text (Maybe Text))
  }
  deriving stock (Show, Eq)
