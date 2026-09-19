{-# LANGUAGE TemplateHaskell #-}

-- | Inspect only the public source embedded at compile time, never runtime files.
-- The bundle hash covers paths and exact UTF-8 contents independently of the git revision.
module Max.SelfSource
  ( SourceMatch (..),
    SourceSlice (..),
    sourceBundleHash,
    sourceFileCount,
    sourceByteCount,
    sourcePaths,
    searchSource,
    readSource,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.FileEmbed (embedFile)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.SelfSource.Embed (embedPublicDir)
import Max.Util (tshow)
import System.FilePath (isPathSeparator, takeExtension, takeFileName, (</>))

data SourceMatch = SourceMatch
  { smPath :: !Text,
    smLine :: !Int,
    smSnippet :: !Text
  }
  deriving stock (Show, Eq)

data SourceSlice = SourceSlice
  { ssPath :: !Text,
    ssStartLine :: !Int,
    ssEndLine :: !Int,
    ssTotalLines :: !Int,
    ssContent :: !Text,
    ssNextLine :: !(Maybe Int)
  }
  deriving stock (Show, Eq)

-- Public source only; runtime configuration and build output stay excluded.
-- file-embed tracks existing files, not directory membership: change this module
-- when adding files. Bundle tests include the archived live-comparison artifacts.
embeddedFiles :: [(FilePath, BS.ByteString)]
embeddedFiles =
  prefixDirectory "src" $(embedPublicDir "src")
    <> prefixDirectory "app" $(embedPublicDir "app")
    <> prefixDirectory "runtime-cli" $(embedPublicDir "runtime-cli")
    <> prefixDirectory "test" $(embedPublicDir "test")
    <> prefixDirectory "test-db" $(embedPublicDir "test-db")
    <> prefixDirectory "test-support" $(embedPublicDir "test-support")
    <> prefixDirectory "migrations" $(embedPublicDir "migrations")
    <> prefixDirectory "docs" $(embedPublicDir "docs")
    <> prefixDirectory "skills" $(embedPublicDir "skills")
    <> prefixDirectory "codemode" $(embedPublicDir "codemode")
    <> prefixDirectory "cbits" $(embedPublicDir "cbits")
    <> prefixDirectory "static" $(embedPublicDir "static")
    <> prefixDirectory "nix" $(embedPublicDir "nix")
    <> prefixDirectory "context-eval" $(embedPublicDir "context-eval")
    <> prefixDirectory "contract-eval" $(embedPublicDir "contract-eval")
    <> prefixDirectory "workflow-eval" $(embedPublicDir "workflow-eval")
    <> prefixDirectory "eval" $(embedPublicDir "eval")
    <> prefixDirectory "prompt-flow" $(embedPublicDir "prompt-flow")
    <> prefixDirectory "scripts" $(embedPublicDir "scripts")
    <> prefixDirectory "browser-image" $(embedPublicDir "browser-image")
    <> prefixDirectory "bridge" $(embedPublicDir "bridge")
    <> prefixDirectory ".github/workflows" $(embedPublicDir ".github/workflows")
    <> [ (".env.example", $(embedFile ".env.example")),
         ("LICENSE", $(embedFile "LICENSE")),
         ("README.md", $(embedFile "README.md")),
         ("max.cabal", $(embedFile "max.cabal")),
         ("cabal.project", $(embedFile "cabal.project")),
         ("flake.nix", $(embedFile "flake.nix")),
         ("flake.lock", $(embedFile "flake.lock")),
         ("devenv.nix", $(embedFile "devenv.nix")),
         ("max.yaml.example", $(embedFile "max.yaml.example"))
       ]

prefixDirectory :: FilePath -> [(FilePath, BS.ByteString)] -> [(FilePath, BS.ByteString)]
prefixDirectory directory = map (first (directory </>))

sourceFiles :: Map Text Text
sourceFiles = Map.fromList (mapMaybe decodeSource embeddedFiles)
  where
    decodeSource (rawPath, bytes)
      | not (allowedTextPath rawPath) = Nothing
      | otherwise = case TE.decodeUtf8' bytes of
          Left _ -> Nothing
          Right body -> Just (portablePath rawPath, body)

allowedTextPath :: FilePath -> Bool
allowedTextPath path =
  takeExtension path
    `elem` [ ".c",
             ".h",
             ".cabal",
             ".css",
             ".example",
             ".hs",
             ".go",
             ".html",
             ".js",
             ".json",
             ".jsonl",
             ".lock",
             ".md",
             ".mod",
             ".nix",
             ".patch",
             ".project",
             ".sh",
             ".sql",
             ".yaml",
             ".yml"
           ]
    || takeFileName path `elem` ["Dockerfile", "LICENSE", "QUICKJS-LICENSE", "nix.conf"]

portablePath :: FilePath -> Text
portablePath = T.pack . map (\c -> if isPathSeparator c then '/' else c)

sourceBundleHash :: Text
sourceBundleHash =
  TE.decodeUtf8 . B16.encode . SHA256.hash . BS.concat $
    [ TE.encodeUtf8 path <> "\0" <> TE.encodeUtf8 body <> "\0"
    | (path, body) <- Map.toAscList sourceFiles
    ]

sourceFileCount :: Int
sourceFileCount = Map.size sourceFiles

sourceByteCount :: Int
sourceByteCount = sum [BS.length (TE.encodeUtf8 body) | body <- Map.elems sourceFiles]

-- | List an exact file or directory-like prefix.  The Bool reports that the
-- bounded response has more entries.
sourcePaths :: Text -> Int -> Either Text ([Text], Bool)
sourcePaths rawPrefix requestedLimit = do
  prefix <- normalizePrefix rawPrefix
  let matches = filter (underPrefix prefix) (Map.keys sourceFiles)
      -- A complete inventory is useful for architecture inspection and still
      -- contains paths only. Keep the cap bounded, but above the repository's
      -- current source-file count so adding a companion bridge does not make
      -- the advertised self snapshot silently partial.
      limit = max 1 (min 1000 requestedLimit)
  pure (take limit matches, length matches > limit)

-- | Case-insensitive literal search.  Results are diversified to at most
-- three matching lines per file before the global cap, so one generated or
-- unusually dense file cannot hide the rest of the implementation.
searchSource :: Text -> Maybe Text -> Int -> Either Text [SourceMatch]
searchSource rawQuery rawPrefix requestedLimit = do
  let query = T.strip rawQuery
  if T.length query < 2
    then Left "query must contain at least two characters"
    else
      if T.length query > 200
        then Left "query is too long (maximum 200 characters)"
        else do
          prefix <- maybe (Right "") normalizePrefix rawPrefix
          let foldedQuery = T.toCaseFold query
              candidates =
                concatMap (fileMatches foldedQuery) . filter (underPrefix prefix . fst) $
                  Map.toAscList sourceFiles
              limit = max 1 (min 30 requestedLimit)
          pure (take limit (map snd (sortOn fst candidates)))
  where
    fileMatches foldedQuery (path, body) =
      let contentMatches =
            take
              3
              [ ( (lineRank foldedQuery foldedLine, path, lineNumber),
                  SourceMatch path lineNumber (T.take 700 line)
                )
              | (lineNumber, line) <- zip [1 ..] (T.lines body),
                let foldedLine = T.toCaseFold line,
                foldedQuery `T.isInfixOf` foldedLine
              ]
          pathMatch =
            [ ( (2 :: Int, path, 1 :: Int),
                SourceMatch path 1 "[path match]"
              )
            | foldedQuery `T.isInfixOf` T.toCaseFold path,
              null contentMatches
            ]
       in contentMatches <> pathMatch

    lineRank query line
      | T.strip line == query = 0 :: Int
      | otherwise = 1

-- | Read one exact allowlisted path with one-based line numbers.  Both line
-- count and rendered characters are bounded so a single generated line cannot
-- consume the whole agent tool-result budget.
readSource :: Text -> Int -> Int -> Either Text SourceSlice
readSource rawPath requestedStart requestedCount = do
  path <- normalizeExactPath rawPath
  body <- maybe (Left "source path not found in the deployed snapshot") Right (Map.lookup path sourceFiles)
  let allLines = T.lines body
      total = length allLines
      start = max 1 requestedStart
  if total > 0 && start > total
    then Left ("start_line is past the end of the file (total " <> tshow total <> ")")
    else do
      let count = max 1 (min 240 requestedCount)
          selected = take count (drop (start - 1) allLines)
          rendered =
            [ tshow lineNumber <> " | " <> cappedLine line
            | (lineNumber, line) <- zip [start ..] selected
            ]
          fitted = takeTextBudget 24000 rendered
          consumed = length fitted
          end = if consumed == 0 then 0 else start + consumed - 1
          next = if end < total then Just (max start (end + 1)) else Nothing
      pure
        SourceSlice
          { ssPath = path,
            ssStartLine = start,
            ssEndLine = end,
            ssTotalLines = total,
            ssContent = T.intercalate "\n" fitted,
            ssNextLine = next
          }
  where
    cappedLine line
      | T.length line <= 4000 = line
      | otherwise = T.take 4000 line <> " …[line truncated]"

takeTextBudget :: Int -> [Text] -> [Text]
takeTextBudget budget = go 0
  where
    go _ [] = []
    go used (line : rest)
      | used + cost <= budget = line : go (used + cost) rest
      | used == 0 = [T.take budget line <> " …[truncated]"]
      | otherwise = []
      where
        cost = T.length line + 1

normalizePrefix :: Text -> Either Text Text
normalizePrefix raw
  | T.null stripped = Right ""
  | otherwise = normalizePath (T.dropWhileEnd (== '/') stripped)
  where
    stripped = T.strip raw

normalizeExactPath :: Text -> Either Text Text
normalizeExactPath raw
  | T.null (T.strip raw) = Left "path cannot be blank"
  | T.isSuffixOf "/" (T.strip raw) = Left "read requires an exact file path"
  | otherwise = normalizePath (T.strip raw)

normalizePath :: Text -> Either Text Text
normalizePath path
  | T.isPrefixOf "/" path = Left "absolute paths are not allowed"
  | T.any (== '\\') path = Left "backslashes are not allowed in source paths"
  | any invalidSegment segments = Left "source path contains an invalid segment"
  | otherwise = Right path
  where
    segments = T.splitOn "/" path
    invalidSegment segment = T.null segment || segment == "." || segment == ".."

underPrefix :: Text -> Text -> Bool
underPrefix "" _ = True
underPrefix prefix path = path == prefix || (prefix <> "/") `T.isPrefixOf` path
