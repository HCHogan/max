-- | Command AST. Syntax is defined in Max.Command.Parser.
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
  = -- | '!unpin <id>'
    UnpinOne !Int64
  | -- | '!unpin' (no arg) — uses the SegReply on the trigger
    UnpinReply
  | -- | '!unpin all'
    UnpinAll
  deriving stock (Show, Eq)

-- | A parsed and structured command.  Unknown commands are represented
-- by 'Unknown' so the dispatcher can give a friendly "did you mean"
-- reply.
data Command
  = -- | '!help' or '!help <topic>'
    Help (Maybe Text)
  | -- | '!model'
    ModelShow
  | -- | '!model list'
    ModelList
  | -- | '!model <name>'
    ModelSet !Text
  | -- | '!debug'
    DebugShow
  | -- | '!debug on' / '!debug off' / '!debug default'
    DebugSet !(Maybe Bool)
  | -- | '!effort'
    EffortShow
  | -- | '!effort <level>' / '!effort default'
    EffortSet !(Maybe Text)
  | -- | '!persona'
    PersonaShow
  | -- | '!persona clear'
    PersonaClear
  | -- | '!persona <text>'
    PersonaSet !Text
  | -- | '!compact' ('!clear' is a compatibility alias)
    Compact
  | -- | '!clear --all' / '!clear -a'
    ClearAll
  | -- | '!unclear' — remove the cleared_at watermark
    Unclear
  | -- | '!pin [id]' — Nothing = use reply target
    Pin !(Maybe Int64)
  | -- | '!unpin [id|all]'
    Unpin !UnpinTarget
  | -- | '!pins'
    Pins
  | -- | '!btw <text>' — a side question that leaves a running turn alone
    Btw !Text
  | -- | '!feedback <text>' / '!fb <text>' — hand a note to a running turn
    Feedback !Text
  | -- | '!ps' (this group)
    PsLocal
  | -- | '!ps --all' / '!ps -a'
    PsAll
  | -- | '!kill <id>'
    Kill !Text
  | -- | '!kill --all' / '!kill -a' — every running task, all groups
    KillAll
  | -- | '! [+pkg…] <cmd>' — leading +pkg tokens put nixpkgs on PATH; rest is the raw shell line, run in the group's sandbox
    Shell ![Text] !Text
  | -- | '!memory' — this group's memories + the caller's own
    MemoryList
  | -- | '!memory rm <id>'
    MemoryRm !Int64
  | -- | '!sticker' — library counters + on/off state
    StickerStats
  | -- | '!sticker on' / 'off' / 'default'
    StickerSet !(Maybe Bool)
  | -- | '!sticker list' — recent captioned stickers
    StickerList
  | -- | '!sticker ban <sha-prefix>'
    StickerBan !Text
  | -- | '!sticker unban <sha-prefix>'
    StickerUnban !Text
  | -- | '!proactive' — feature + override state
    ProactiveStatus
  | -- | '!proactive on' / 'off' / 'default'
    ProactiveSet !(Maybe Bool)
  | -- | '!version'
    Version
  | -- | '!use' — current admin target group (private chat)
    UseShow
  | -- | '!use <群号>' — aim following commands at that group
    UseSet !Int64
  | -- | '!use clear'
    UseClear
  | -- | '!status' — overview of the (target) group
    Status
  | -- | verb + raw args; parser succeeded but verb unknown
    Unknown !Text !RawArgs
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
