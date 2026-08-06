-- |
-- The @!version@ card, in a leaf module for the same reason
-- "Max.Command.Help" is one: the @self-knowledge@ builtin skill
-- splices part of it at registry init ("Max.Skills" replaces
-- @{{version}}@), so what the bot tells a group about its build and
-- what it tells itself can't drift apart.
--
-- The card is split along the only line that matters for splicing:
-- 'buildIdentityLines' is fixed for the process's lifetime (version,
-- revision, OS, arch, toolchain) and is therefore safe to bake into a
-- skill body at boot, while uptime and the per-group tool/skill counts
-- are live status — they belong to the command, which reads them per
-- invocation.  Splicing those would hand the model a boot-time
-- snapshot it would still be quoting days later.
--
-- Imports stay light: "Max.Skills" sits below "Max.Env" in the import
-- graph, and this module has to sit below "Max.Skills".
module Max.Command.Version
  ( buildIdentityLines,
    versionCard,
    readOsPretty,
    readHostUptime,
    fmtDur,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Version (showVersion)
import Distribution.Pretty (prettyShow)
import Distribution.Simple.Utils (cabalVersion)
import Max.BuildInfo (gitRev)
import Max.Util (trySyncIO, tshow)
import Paths_max (version)
import System.Info (arch, fullCompilerVersion, os)
import Text.Read (readMaybe)

-- | The part of the card that answers "which build am I": constant
-- from boot to shutdown, so 'Max.Skills' can bake it into
-- @self-knowledge@ once.  Takes the distro name because reading it is
-- IO ('readOsPretty') and both callers already have one in hand.
buildIdentityLines :: Text -> [Text]
buildIdentityLines osName =
  [ "🦈 max v" <> T.pack (showVersion version) <> maybe "" (\r -> " (" <> T.pack r <> ")") gitRev,
    "🌊 " <> osName <> " · " <> T.pack arch,
    "🫧 ghc " <> T.pack (showVersion fullCompilerVersion) <> " · cabal " <> T.pack (prettyShow cabalVersion)
  ]

-- | The full @!version@ reply: build identity plus live status.
--
-- Single newlines only — a blank line would split the card into
-- separate messages ('Max.Reply.planReply').
versionCard ::
  -- | distro name ('readOsPretty')
  Text ->
  -- | tools visible to this group's dispatches
  Int ->
  -- | skills visible to this group
  Int ->
  -- | bot uptime, seconds
  Double ->
  -- | host uptime, seconds ('readHostUptime')
  Maybe Double ->
  Text
versionCard osName toolCount skillCount botUp hostUp =
  T.intercalate "\n" $
    buildIdentityLines osName
      <> [ "🐚 " <> tshow toolCount <> " tools · " <> tshow skillCount <> " skills",
           "⏱️ up " <> fmtDur botUp <> maybe "" (\u -> " · host " <> fmtDur u) hostUp
         ]

-- | Distro name from @/etc/os-release@'s @PRETTY_NAME@; falls back to
-- the compiler's notion of the OS.
readOsPretty :: IO Text
readOsPretty = do
  r <- trySyncIO (TIO.readFile "/etc/os-release")
  pure $ case r of
    Right c
      | (l : _) <- [l | l <- T.lines c, "PRETTY_NAME=" `T.isPrefixOf` l] ->
          T.dropAround (== '"') (T.drop (T.length "PRETTY_NAME=") l)
    _ -> T.pack os

-- | Host uptime in seconds (@/proc/uptime@'s first field).
readHostUptime :: IO (Maybe Double)
readHostUptime = do
  r <- trySyncIO (TIO.readFile "/proc/uptime")
  pure $ case r of
    Right c | (w : _) <- T.words c, Just d <- readMaybe (T.unpack w) -> Just d
    _ -> Nothing

-- | Compact duration: the two most significant units (@3d 4h@,
-- @2h 13m@, @5m 12s@).
fmtDur :: Double -> Text
fmtDur secs =
  let s = max 0 (round secs) :: Int
      (d, s1) = s `divMod` 86400
      (h, s2) = s1 `divMod` 3600
      (m, sec) = s2 `divMod` 60
   in case () of
        _
          | d > 0 -> tshow d <> "d " <> tshow h <> "h"
          | h > 0 -> tshow h <> "h " <> tshow m <> "m"
          | m > 0 -> tshow m <> "m " <> tshow sec <> "s"
          | otherwise -> tshow sec <> "s"
