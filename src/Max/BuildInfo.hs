{-# LANGUAGE TemplateHaskell #-}

-- |
-- The git revision baked into the binary at compile time, shown by
-- @!version@ and the admin overview.  Two sources, tried in order:
--
-- 1. @MAX_GIT_REV@ in the build environment — the flake sets it from
--    @self.shortRev@, because the nix source tree is cleaned of
--    @.git@ and the fallback below would find nothing there.
-- 2. @git rev-parse --short HEAD@ in the working tree (dev cabal
--    builds), with a @-dirty@ suffix when the tree has local changes.
--
-- Dev-build staleness: GHC re-runs the splice only when this module
-- recompiles, so @.git\/HEAD@ is registered as a dependency — a new
-- commit or branch switch triggers the rebuild.  Edits without a
-- commit stay invisible to the hash, which is what @-dirty@ is for.
module Max.BuildInfo
  ( gitRev,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Char (isSpace)
import Data.List (dropWhileEnd)
import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO)
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

-- | @Just "382d4f2"@ / @Just "382d4f2-dirty"@, or 'Nothing' when the
-- build had neither @MAX_GIT_REV@ nor a readable git repo.
--
-- Everything lives inside the splice: the GHC stage restriction
-- forbids a top-level same-module helper here.
gitRev :: Maybe String
gitRev =
  $( do
       let strip = dropWhileEnd isSpace . dropWhile isSpace
           resolveRev = do
             fromEnv <- lookupEnv "MAX_GIT_REV"
             case strip <$> fromEnv of
               -- "unknown" is the flake's explicit shrug (rev
               -- unavailable, e.g. a tarball build) = unset.
               Just r | not (null r), r /= "unknown" -> pure (Just r)
               _ -> do
                 eres <- try @IOException $ do
                   (code, out, _) <- readProcessWithExitCode "git" ["rev-parse", "--short", "HEAD"] ""
                   (scode, sout, _) <- readProcessWithExitCode "git" ["status", "--porcelain"] ""
                   pure (code, strip out, scode == ExitSuccess && not (null (strip sout)))
                 pure $ case eres of
                   Right (ExitSuccess, rev, dirty)
                     | not (null rev) -> Just (rev <> if dirty then "-dirty" else "")
                   _ -> Nothing
       headExists <- runIO (doesFileExist ".git/HEAD")
       when headExists (addDependentFile ".git/HEAD")
       runIO resolveRev >>= lift
   )
