-- | Match Git's local exclusions before embedding public source. Nix builds
-- receive an already filtered source tree and do not need Git at build time.
module Max.SelfSource.Embed (embedPublicDir) where

import Data.FileEmbed (embedFile, getDir)
import Data.Set qualified as Set
import Language.Haskell.TH (Exp, Q, listE, tupE)
import Language.Haskell.TH.Syntax (lift, runIO)
import System.Directory (doesPathExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

embedPublicDir :: FilePath -> Q Exp
embedPublicDir directory = do
  files <- map fst <$> runIO (getDir directory)
  local <- runIO (doesPathExist ".git")
  ignored <-
    if not local || null files
      then pure Set.empty
      else do
        let input = concatMap (\path -> directory </> path <> "\0") files
        (status, output, detail) <- runIO (readProcessWithExitCode "git" ["check-ignore", "--stdin", "-z"] input)
        case status of
          ExitSuccess -> pure (Set.fromList (splitNull output))
          ExitFailure 1 -> pure Set.empty
          _ -> fail ("cannot check source exclusions: " <> detail)
  listE [tupE [lift path, embedFile (directory </> path)] | path <- files, Set.notMember (directory </> path) ignored]
  where
    splitNull [] = []
    splitNull input = let (path, rest) = break (== '\0') input in path : splitNull (drop 1 rest)
