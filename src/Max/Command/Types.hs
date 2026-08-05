-- |
-- AST for the @!@-prefixed command DSL.  Parsing happens in
-- "Max.Command.Parser"; per-command behaviour in "Max.Command.Dispatcher".
--
-- == Grammar
--
-- > command  ::= '!' ident (whitespace+ arg)*
-- > arg      ::= longflag | shortflags | value
-- > longflag ::= '--' ident ('=' value)?
-- > shortflags ::= '-' letter+            -- e.g. -a, or bundled -dg
-- > value    ::= barestring | "..." | '...'
-- > ident    ::= [a-zA-Z][a-zA-Z0-9-]*
--
-- Short flags are single-letter aliases of long flags (@-a@ = @--all@,
-- @-d@ = @--deny@, @-g@ = @--global@; see 'Max.Command.Parser.shortFlagAlias')
-- and are boolean-only.  A cluster expands letter-by-letter, so @-dg@
-- means @--deny --global@.  A dash-run is only treated as flags when
-- every letter is a known alias — otherwise it stays a positional value,
-- so a negative id (@-1@) or free text (@-cool@) is preserved.
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
  | DebugShow -- ^ '!debug'
  | DebugSet !(Maybe Bool) -- ^ '!debug on' / '!debug off' / '!debug default'
  | EffortShow -- ^ '!effort'
  | EffortSet !(Maybe Text) -- ^ '!effort <level>' / '!effort default'
  | PersonaShow -- ^ '!persona'
  | PersonaClear -- ^ '!persona clear'
  | PersonaSet !Text -- ^ '!persona <text>'
  | Clear -- ^ '!clear'
  | ClearAll -- ^ '!clear --all' / '!clear -a'
  | Unclear -- ^ '!unclear' — remove the cleared_at watermark
  | Pin !(Maybe Int64) -- ^ '!pin [id]' — Nothing = use reply target
  | Unpin !UnpinTarget -- ^ '!unpin [id|all]'
  | Pins -- ^ '!pins'
  | Btw !Text -- ^ '!btw <text>' — a side question that leaves a running turn alone
  | Feedback !Text -- ^ '!feedback <text>' / '!fb <text>' — hand a note to a running turn
  | PsLocal -- ^ '!ps' (this group)
  | PsAll -- ^ '!ps --all' / '!ps -a'
  | Kill !Text -- ^ '!kill <id>'
  | KillAll -- ^ '!kill --all' / '!kill -a' — every running task, all groups
  | Shell ![Text] !Text -- ^ '! [+pkg…] <cmd>' — leading +pkg tokens put nixpkgs on PATH; rest is the raw shell line, run in the group's sandbox
  | MemoryList -- ^ '!memory' — this group's memories + the caller's own
  | MemoryRm !Int64 -- ^ '!memory rm <id>'
  | StickerStats -- ^ '!sticker' — library counters + on/off state
  | StickerSet !(Maybe Bool) -- ^ '!sticker on' / 'off' / 'default'
  | StickerList -- ^ '!sticker list' — recent captioned stickers
  | StickerBan !Text -- ^ '!sticker ban <sha-prefix>'
  | StickerUnban !Text -- ^ '!sticker unban <sha-prefix>'
  | ProactiveStatus -- ^ '!proactive' — feature + override state
  | ProactiveSet !(Maybe Bool) -- ^ '!proactive on' / 'off' / 'default'
  | Version -- ^ '!version'
  | UseShow -- ^ '!use' — current admin target group (private chat)
  | UseSet !Int64 -- ^ '!use <群号>' — aim following commands at that group
  | UseClear -- ^ '!use clear'
  | Status -- ^ '!status' — overview of the (target) group
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
