{-# LANGUAGE TemplateHaskell #-}

-- |
-- The public source snapshot that shipped inside this binary.
--
-- This is deliberately not a host-filesystem reader.  Agent tools can inspect
-- only the fixed roots and named, compile-time text below, so a source question
-- can never turn into a read of local @max.yaml@, @/var/lib/max-bot@, or another
-- runtime path.  The bundle hash is
-- over path + exact UTF-8 contents and identifies the snapshot independently of
-- the friendly git revision.
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
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.FileEmbed (embedDir, embedFile)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Bifunctor (first)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.FilePath (isPathSeparator, takeExtension, takeFileName, (</>))
import Max.Util (tshow)

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

-- Keep the boundary explicit.  In particular, no @.env@, local @max.yaml@,
-- @AGENTS.md@, VCS metadata, build output, or runtime state is reachable.
-- file-embed tracks existing files rather than directory membership, so adding
-- an eligible file under one of these roots must accompany a byte change here;
-- the source-bundle tests then prove that the new file shipped.
embeddedFiles :: [(FilePath, BS.ByteString)]
embeddedFiles =
  prefixDirectory "src" $(embedDir "src")
    <> prefixDirectory "app" $(embedDir "app")
    <> prefixDirectory "test" $(embedDir "test")
    <> prefixDirectory "test-db" $(embedDir "test-db")
    <> prefixDirectory "migrations" $(embedDir "migrations")
    <> prefixDirectory "docs" $(embedDir "docs")
    <> prefixDirectory "skills" $(embedDir "skills")
    <> prefixDirectory "static" $(embedDir "static")
    <> prefixDirectory "nix" $(embedDir "nix")
    <> prefixDirectory "context-eval" $(embedDir "context-eval")
    <> prefixDirectory "eval" $(embedDir "eval")
    <> prefixDirectory "prompt-flow" $(embedDir "prompt-flow")
    <> prefixDirectory "scripts" $(embedDir "scripts")
    <> prefixDirectory "sandbox-image" $(embedDir "sandbox-image")
    <> prefixDirectory "browser-image" $(embedDir "browser-image")
    <> prefixDirectory "bridge" $(embedDir "bridge")
    <> prefixDirectory ".github/workflows" $(embedDir ".github/workflows")
    <> [ (".env.example", $(embedFile ".env.example")),
         ("LICENSE", $(embedFile "LICENSE")),
         ("README.md", $(embedFile "README.md")),
         ("max.cabal", $(embedFile "max.cabal")),
         ("cabal.project", $(embedFile "cabal.project")),
         ("flake.nix", $(embedFile "flake.nix")),
         ("flake.lock", $(embedFile "flake.lock")),
         ("devenv.nix", $(embedFile "devenv.nix")),
         ("docker-compose.yml", $(embedFile "docker-compose.yml")),
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
    `elem` [ ".cabal",
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
    || takeFileName path `elem` ["Dockerfile", "LICENSE", "nix.conf"]

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
            take 3
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
