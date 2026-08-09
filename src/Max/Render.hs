-- |
-- Render a markdown table to a PNG via the @typst@ CLI, and a fenced code
-- block to a PNG via the @codesnap@ CLI.  QQ has no markdown and no
-- monospace guarantee, so both go out as images; the caller falls back to
-- sending text when this fails (binary missing, weird input, timeout).
module Max.Render
  ( renderTableImage,
    renderCodeImage,
  )
where

import Control.Exception (IOException, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.Util (withTempDirectory)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

-- | Markdown table source (as carved out by 'Max.Reply.planReply')
-- to PNG bytes.  Never throws; every failure mode comes back 'Left'.
renderTableImage :: Text -> IO (Either Text ByteString)
renderTableImage src = case parseTable src of
  Nothing -> pure (Left "not a parseable markdown table")
  Just tbl -> compileTypst (tableToTypst tbl)

--------------------------------------------------------------------------------
-- Fenced code -> PNG, via codesnap.

-- | A code block's body (fences already stripped) and its info string to
-- PNG bytes.  Never throws; every failure mode comes back 'Left'.
--
-- The language is a hint only.  codesnap rejects an unknown one, and the
-- model writes whatever it likes after the backticks, so an unrecognised
-- tag must not cost the whole picture: the render is retried once with no
-- language, which loses highlighting and keeps the snippet.
renderCodeImage :: Maybe Text -> Text -> IO (Either Text ByteString)
renderCodeImage lang code
  | T.null (T.strip code) = pure (Left "empty code block")
  | otherwise =
      runCodesnap lang code >>= \case
        Right png -> pure (Right png)
        Left err -> case lang of
          Nothing -> pure (Left err)
          Just _ -> runCodesnap Nothing code

runCodesnap :: Maybe Text -> Text -> IO (Either Text ByteString)
runCodesnap lang code = do
  r <- try @IOException run
  pure $ case r of
    Left e -> Left ("codesnap spawn failed: " <> T.pack (show e))
    Right res -> res
  where
    run = withTempDirectory "max-code-" $ \workspace -> do
      let inPath = workspace </> "snippet.txt"
          outPath = workspace </> "snippet.png"
      BS.writeFile inPath (TE.encodeUtf8 code)
      result <-
        timeout 20_000_000 $
          readProcessWithExitCode "codesnap" (codesnapArgs lang inPath outPath) ""
      case result of
        Nothing -> pure (Left "codesnap timed out")
        Just (ExitSuccess, _, _) -> do
          -- codesnap reports a failed render on stdout and still exits 0
          -- (an unknown --language does exactly this), so the artefact is
          -- the only trustworthy success signal.
          wrote <- doesFileExist outPath
          if wrote
            then Right <$> BS.readFile outPath
            else pure (Left "codesnap wrote no image")
        Just (ExitFailure c, out, err) ->
          pure . Left $
            "codesnap exited "
              <> T.pack (show c)
              <> ": "
              <> T.pack (take 500 (err <> out))

-- | Everything visual is pinned here rather than left to codesnap's
-- defaults, which live in a config file it writes into @$HOME@ on first
-- run and may change between versions.
codesnapArgs :: Maybe Text -> FilePath -> FilePath -> [String]
codesnapArgs lang inPath outPath =
  [ "--from-file",
    inPath,
    "--output",
    outPath,
    "--silent",
    -- Recursive covers no CJK, so the module installs Sarasa Mono beside it
    -- and fontconfig supplies the missing glyphs per character: a Chinese
    -- comment renders instead of turning into tofu, without the Latin
    -- giving up its ligatures.
    "--code-font-family",
    "RecMonoCasual Nerd Font Mono",
    "--has-line-number",
    -- A watermark and a fake title bar are decoration on something being
    -- read on a phone.
    "--watermark",
    "",
    "--mac-window-bar",
    "false",
    -- Transparent, not @--shadow-radius 0@.  Zero radius does not remove
    -- the shadow, it removes its /blur/: the default \#00000040 then lands
    -- as a hard-edged dark block under the window, the width of the window
    -- and nothing like a shadow.  Killing the colour is what removes it.
    "--shadow-color",
    "#00000000",
    -- Scale buys nothing at a glance and everything on a second look.
    -- A chat client fits the picture to the bubble, so what decides
    -- unzoomed legibility is characters per line, not pixels: measured on
    -- a 300dp bubble, scale 2 and scale 3 give an identical ~4.2 dp per
    -- character at 60 columns and ~2.5 at 100.  Where they differ is the
    -- tap-to-zoom view — 23 real pixels per character against 15 — and a
    -- long line is exactly what gets tapped.  The cost is bytes alone.
    "--scale-factor",
    "3",
    "--margin-x",
    "16",
    "--margin-y",
    "16"
  ]
    <> maybe [] (\l -> ["--language", T.unpack l]) lang

--------------------------------------------------------------------------------
-- Markdown table -> typst source.

data Table = Table
  { aligns :: ![Text], -- typst alignment names, one per column
    headerRow :: ![Text],
    bodyRows :: ![[Text]]
  }

parseTable :: Text -> Maybe Table
parseTable src = case filter (not . T.null) (map T.strip (T.lines src)) of
  (h : sep : rest) -> do
    let header = splitRow h
        seps = splitRow sep
        cols = maximum (length header : map (length . splitRow) rest)
        pad r = take cols (r <> repeat "")
    Just
      Table
        { aligns = take cols (map sepAlign seps <> repeat "left"),
          headerRow = pad header,
          bodyRows = map (pad . splitRow) rest
        }
  _ -> Nothing

-- | Split @| a | b |@ into cells, honouring @\\|@ escapes.
splitRow :: Text -> [Text]
splitRow = map (T.replace "\\|" "|" . T.strip) . go . trim
  where
    trim = T.dropWhileEnd (== '|') . T.dropWhile (== '|') . T.strip
    go t = case T.breakOn "|" t of
      (cell, rest)
        | T.null rest -> [cell]
        | "\\" `T.isSuffixOf` cell ->
            case go (T.drop 1 rest) of
              (next : more) -> (cell <> "|" <> next) : more
              [] -> [cell <> "|"]
        | otherwise -> cell : go (T.drop 1 rest)

sepAlign :: Text -> Text
sepAlign s
  | colonL && colonR = "center"
  | colonR = "right"
  | otherwise = "left"
  where
    colonL = ":" `T.isPrefixOf` s
    colonR = ":" `T.isSuffixOf` s

tableToTypst :: Table -> Text
tableToTypst tbl =
  T.unlines
    [ "#set page(width: auto, height: auto, margin: 12pt, fill: white)",
      -- Source Han Sans is the face we ship via TYPST_FONT_PATHS
      -- (nixpkgs' noto CJK is variable-font-only, which typst can't
      -- render); the rest are fallbacks for bare dev machines.
      "#set text(size: 12pt, font: (\"Source Han Sans SC\", \"Noto Sans CJK SC\", \"PingFang SC\"))",
      "#show table.cell.where(y: 0): strong",
      "#table(",
      "  columns: " <> T.pack (show (length tbl.aligns)) <> ",",
      "  align: (" <> T.intercalate ", " tbl.aligns <> ",),",
      "  stroke: 0.5pt + luma(160),",
      "  inset: 7pt,",
      "  fill: (_, y) => if y == 0 { luma(240) } else { white },",
      T.intercalate ",\n" (map row (tbl.headerRow : tbl.bodyRows)) <> ",",
      ")"
    ]
  where
    row cells = "  " <> T.intercalate ", " (map str cells)
    -- Cells go in as typst string literals: no markup interpretation,
    -- so any # * _ $ in the content is safe.
    str c = "\"" <> T.replace "\"" "\\\"" (T.replace "\\" "\\\\" c) <> "\""

--------------------------------------------------------------------------------
-- typst CLI.

compileTypst :: Text -> IO (Either Text ByteString)
compileTypst source = do
  r <- try @IOException run
  pure $ case r of
    Left e -> Left ("typst spawn failed: " <> T.pack (show e))
    Right res -> res
  where
    run = withTempDirectory "max-table-" $ \workspace -> do
      let inPath = workspace </> "table.typ"
          outPath = workspace </> "table.png"
      BS.writeFile inPath (TE.encodeUtf8 source)
      result <-
        timeout 15_000_000 $
          readProcessWithExitCode
            "typst"
            ["compile", "--format", "png", "--ppi", "144", inPath, outPath]
            ""
      case result of
        Nothing -> pure (Left "typst timed out")
        Just (ExitSuccess, _, _) -> Right <$> BS.readFile outPath
        Just (ExitFailure c, _, err) ->
          pure . Left $
            "typst exited " <> T.pack (show c) <> ": " <> T.pack (take 500 err)
