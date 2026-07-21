-- |
-- Reply post-processing: turn the LLM's final markdown-ish reply into
-- a plan of outgoing messages.  QQ renders none of markdown — chats
-- read as multiple short plain-text messages — so the pipeline:
--
--   1. carves out markdown tables ('TableChunk', rendered to an image
--      by the caller; plain-text tables are unreadable in a
--      proportional font),
--   2. rewrites LaTeX math into best-effort unicode (QQ can't render
--      formulas at all),
--   3. splits the remaining text into one message per blank-line
--      paragraph (code fences never split),
--   4. caps the total at 'maxReplyChunks' messages, folding overflow
--      into the last one so a rambling reply can't flood the chat.
--
-- Everything here is pure; the effectful part (typst rendering,
-- sending) lives with the caller.
module Max.Reply
  ( Chunk (..),
    chunkSource,
    planReply,
    maxReplyChunks,
    latexToUnicode,
    ReplyPiece (..),
    parseReplyTokens,
  )
where

import Control.Applicative ((<|>))
import Data.Char (isAlpha, isDigit, isSpace)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR

-- | One outgoing message.  'TableChunk' carries the markdown table
-- source — the caller renders it to an image and falls back to
-- sending the source verbatim if rendering fails.
data Chunk
  = TextChunk !Text
  | TableChunk !Text
  deriving stock (Show, Eq)

-- | The text a chunk was planned from — what should go into the
-- bot's own history (the model should see the table it wrote, not
-- an image), and the fallback when rendering fails.
chunkSource :: Chunk -> Text
chunkSource = \case
  TextChunk t -> t
  TableChunk t -> t

maxReplyChunks :: Int
maxReplyChunks = 5

planReply :: Text -> [Chunk]
planReply body =
  case capChunks (concatMap explode (splitTables body)) of
    [] -> [TextChunk (T.strip body)]
    cs -> cs
  where
    explode (TableChunk t) = [TableChunk t]
    explode (TextChunk t) = map TextChunk (splitParagraphs (latexToUnicode t))

--------------------------------------------------------------------------------
-- Outbound placeholders: [↩#<id>] quotes and [表情包#<id>] stickers.

-- | A parsed span of one planned text chunk.  'PieceText' still holds
-- raw @\@\<qq\>@ spans — mention conversion happens later, per piece.
data ReplyPiece
  = PieceText !Text
  | PieceSticker !Int64
  | -- | A @[image#\<message_id\>]@ resend of a stored group image.
    PieceImage !Int64
  deriving stock (Show, Eq)

-- | Pull the reply/sticker/image placeholders out of one planned text
-- chunk.
--
--   * @[↩#\<id\>]@ — a quote.  The first one becomes the chunk's reply
--     target ('fst' of the result); every @[↩#…]@ token is stripped
--     from the text regardless of position.
--   * @[表情包#\<id\>]@ — a sticker, becomes a 'PieceSticker'.  The
--     inbound display form @[表情包#\<id\>: …]@ is accepted too (the
--     trailing caption is ignored) so echoing what was seen still sends.
--   * @[image#\<message_id\>]@ — resend a stored group image, becomes a
--     'PieceImage' (the same handle the model reads inbound).
--
-- Anything that isn't a well-formed token stays literal 'PieceText'.
-- Pure by design: the sticker/image ids are turned into segments by the
-- effectful caller (see 'Max.Handler.sendAndPersistReply').
parseReplyTokens :: Text -> (Maybe Int64, [ReplyPiece])
parseReplyTokens = go
  where
    go t = case T.breakOn "[" t of
      (before, rest)
        | T.null rest -> (Nothing, prepend before [])
        | otherwise -> case matchToken rest of
            Just (TokReply n, rest') ->
              let (mrid, ps) = go rest'
               in (Just n <|> mrid, prepend before ps)
            Just (TokSticker n, rest') ->
              let (mrid, ps) = go rest'
               in (mrid, prepend before (PieceSticker n : ps))
            Just (TokImage n, rest') ->
              let (mrid, ps) = go rest'
               in (mrid, prepend before (PieceImage n : ps))
            Nothing ->
              let (mrid, ps) = go (T.drop 1 rest)
               in (mrid, prepend (before <> "[") ps)

    -- Fold literal text into the head 'PieceText', avoiding empties and
    -- adjacent text pieces.
    prepend s ps
      | T.null s = ps
      | otherwise = case ps of
          (PieceText t : rest) -> PieceText (s <> t) : rest
          _ -> PieceText s : ps

data Token = TokReply !Int64 | TokSticker !Int64 | TokImage !Int64

matchToken :: Text -> Maybe (Token, Text)
matchToken t =
  (do rest <- T.stripPrefix "[↩#" t; (n, r) <- idClose rest; pure (TokReply n, r))
    <|> (do rest <- T.stripPrefix "[image#" t; (n, r) <- idClose rest; pure (TokImage n, r))
    <|> (do rest <- T.stripPrefix "[表情包#" t; (n, r) <- stickerClose rest; pure (TokSticker n, r))
  where
    -- reply / image: digits then an immediate ']'.
    idClose s =
      let (digits, rest) = T.span isDigit s
       in if T.null digits
            then Nothing
            else (,) <$> readInt64 digits <*> T.stripPrefix "]" rest
    -- sticker: digits then ']', or ':' + caption (up to the next ']').
    stickerClose s =
      let (digits, rest) = T.span isDigit s
       in if T.null digits
            then Nothing
            else do
              n <- readInt64 digits
              case T.uncons rest of
                Just (']', r) -> Just (n, r)
                Just (':', r') -> case T.breakOn "]" r' of
                  (_, close) | not (T.null close) -> Just (n, T.drop 1 close)
                  _ -> Nothing
                _ -> Nothing

readInt64 :: Text -> Maybe Int64
readInt64 s = case TR.decimal s of
  Right (n, "") -> Just n
  _ -> Nothing

--------------------------------------------------------------------------------
-- Stage 1: carve out markdown tables.

-- | Split on GFM tables: a line starting with @|@ immediately
-- followed by a separator row (only @| - : space@, at least one
-- dash), plus any following @|@-lines.  Conservative on purpose —
-- a lone @|@-prefixed line stays text.  Fence-aware: table syntax
-- inside ``` is code.
splitTables :: Text -> [Chunk]
splitTables body = go False [] (T.lines body)
  where
    go _ acc []
      = flushText acc []
    go inFence acc (l : rest)
      | isFence l = go (not inFence) (l : acc) rest
      | inFence = go True (l : acc) rest
      | Just (tbl, rest') <- takeTable (l : rest) =
          flushText acc (TableChunk (T.intercalate "\n" tbl) : go False [] rest')
      | otherwise = go False (l : acc) rest
    flushText acc more =
      let t = T.strip (T.intercalate "\n" (reverse acc))
       in if T.null t then more else TextChunk t : more

takeTable :: [Text] -> Maybe ([Text], [Text])
takeTable (header : sep : rest)
  | isPipeRow header && isSepRow sep =
      let (bodyRows, rest') = span isPipeRow rest
       in Just (header : sep : bodyRows, rest')
takeTable _ = Nothing

isPipeRow :: Text -> Bool
isPipeRow l = "|" `T.isPrefixOf` T.stripStart l

isSepRow :: Text -> Bool
isSepRow l =
  let s = T.strip l
   in isPipeRow s
        && T.any (== '-') s
        && T.all (\c -> c `elem` ("|-: " :: String)) s

isFence :: Text -> Bool
isFence l = "```" `T.isPrefixOf` T.stripStart l

--------------------------------------------------------------------------------
-- Stage 3: blank-line paragraph split (fence-aware).

splitParagraphs :: Text -> [Text]
splitParagraphs body = go False [] (T.lines body)
  where
    go _ acc [] = flush acc []
    go inFence acc (l : rest)
      | isFence l = go (not inFence) (l : acc) rest
      | not inFence && isBlank l = flush acc (go False [] rest)
      | otherwise = go inFence (l : acc) rest
    flush acc more =
      let chunk = T.strip (T.intercalate "\n" (reverse acc))
       in if T.null chunk then more else chunk : more
    isBlank = T.null . T.strip

--------------------------------------------------------------------------------
-- Stage 4: cap.

-- | Overflow folds into a final 'TextChunk' — a table caught in the
-- fold degrades to its markdown source, which is the same fallback
-- as a failed render.
capChunks :: [Chunk] -> [Chunk]
capChunks xs
  | length xs <= maxReplyChunks = xs
  | otherwise =
      take (maxReplyChunks - 1) xs
        <> [ TextChunk
               ( T.intercalate
                   "\n\n"
                   (map chunkSource (drop (maxReplyChunks - 1) xs))
               )
           ]

--------------------------------------------------------------------------------
-- Stage 2: LaTeX → best-effort unicode.

-- | Rewrite LaTeX math regions — @\\(..\\)@, @\\[..\\]@, @$$..$$@,
-- and conservatively @$..$@ — into plain unicode.  Code fences and
-- inline backtick spans are left untouched.  Unbalanced delimiters
-- and constructs we don't understand pass through unchanged: the
-- goal is "readable in QQ", not a TeX engine.
latexToUnicode :: Text -> Text
latexToUnicode body =
  T.intercalate "\n" (goLines False (T.lines body))
  where
    goLines _ [] = []
    goLines inFence (l : rest)
      | isFence l = l : goLines (not inFence) rest
      | inFence = l : goLines True rest
      | otherwise = rewriteLine l : goLines False rest

-- | Rewrite math regions in one line, skipping @`code`@ spans.
rewriteLine :: Text -> Text
rewriteLine = go
  where
    go t
      | T.null t = t
      | Just rest <- T.stripPrefix "`" t =
          case T.breakOn "`" rest of
            (code, rest') | not (T.null rest') ->
              "`" <> code <> "`" <> go (T.drop 1 rest')
            _ -> t
      | Just rest <- T.stripPrefix "$$" t = delim "$$" "$$" rest
      | Just rest <- T.stripPrefix "\\(" t = delim "\\(" "\\)" rest
      | Just rest <- T.stripPrefix "\\[" t = delim "\\[" "\\]" rest
      | Just rest <- T.stripPrefix "$" t = singleDollar rest
      | otherwise =
          let (safe, t') = T.break (\c -> c `elem` ("`$\\" :: String)) t
           in if T.null safe
                then T.take 1 t' <> go (T.drop 1 t')
                else safe <> go t'
    delim open close rest = case T.breakOn close rest of
      (math, rest') | not (T.null rest') ->
        texMath math <> go (T.drop (T.length close) rest')
      _ -> open <> rest -- unbalanced: leave the tail untouched
    -- $..$ only counts as math when the content is non-empty, stays
    -- on one line, doesn't start/end with space (GFM's own rule, and
    -- it kills "$5 and $10"), and actually smells like TeX.
    singleDollar rest = case T.breakOn "$" rest of
      (math, rest')
        | not (T.null rest'),
          not (T.null math),
          not (isSpace (T.head math)),
          not (isSpace (T.last math)),
          T.any (\c -> c `elem` ("\\^_" :: String)) math ->
            texMath math <> go (T.drop 1 rest')
      _ -> "$" <> go rest

-- | Convert the inside of a math region.
texMath :: Text -> Text
texMath = squeeze . go
  where
    go t
      | T.null t = ""
      | Just rest <- T.stripPrefix "\\" t = command rest
      | Just rest <- T.stripPrefix "^" t = script superscriptMap "^" rest
      | Just rest <- T.stripPrefix "_" t = script subscriptMap "_" rest
      | Just rest <- T.stripPrefix "{" t =
          let (inner, rest') = matchBrace rest
           in go inner <> go rest'
      | Just rest <- T.stripPrefix "}" t = go rest
      | otherwise = T.take 1 t <> go (T.drop 1 t)

    command rest =
      let (name, rest') = T.span isAlpha rest
       in case name of
            "" -> case T.uncons rest of
              -- \, \; \! \: — spacing; \{ \} \| — literal
              Just (c, rest'')
                | c `elem` (",;!:" :: String) -> go rest''
                | otherwise -> T.singleton c <> go rest''
              Nothing -> ""
            "frac" ->
              let (a, r1) = arg rest'
                  (b, r2) = arg r1
               in wrap (go a) <> "/" <> wrap (go b) <> go r2
            "sqrt" ->
              let (a, r1) = arg rest'
               in "√(" <> go a <> ")" <> go r1
            _
              | Just (n, taking) <- Map.lookup name argCommands ->
                  let (as, r') = args n rest'
                   in taking (map go as) <> go r'
              | Just sym <- Map.lookup name symbols -> sym <> go rest'
              | name `elem` plainNames -> name <> go rest'
              | otherwise -> name <> go rest' -- unknown: drop the backslash

    -- ^/_ argument: braced group, a command (\alpha), or one char.
    script table lit rest = case T.uncons rest of
      Just ('{', _) ->
        let (inner, rest') = matchBrace (T.drop 1 rest)
            converted = go inner
         in mapScript table lit converted <> go rest'
      Just ('\\', _) ->
        let (name, rest') = T.span isAlpha (T.drop 1 rest)
            converted = go ("\\" <> name)
         in mapScript table lit converted <> go rest'
      Just (c, rest') -> mapScript table lit (T.singleton c) <> go rest'
      Nothing -> lit

    arg t = case T.uncons (T.stripStart t) of
      Just ('{', rest) -> matchBrace rest
      Just (c, rest) -> (T.singleton c, rest)
      Nothing -> ("", "")

    args :: Int -> Text -> ([Text], Text)
    args 0 t = ([], t)
    args n t = let (a, t') = arg t; (as, t'') = args (n - 1) t' in (a : as, t'')

    wrap t
      | T.length t <= 1 || T.all (\c -> isAlpha c || isDigit c) t = t
      | otherwise = "(" <> t <> ")"

    squeeze = T.unwords . T.words

-- | Take the content of an already-opened brace group (input starts
-- just past @{@); returns (inner, after-close).
matchBrace :: Text -> (Text, Text)
matchBrace = go (0 :: Int) []
  where
    go _ acc t | T.null t = (T.pack (reverse acc), "")
    go depth acc t =
      let c = T.head t
          rest = T.tail t
       in case c of
            '{' -> go (depth + 1) (c : acc) rest
            '}'
              | depth == 0 -> (T.pack (reverse acc), rest)
              | otherwise -> go (depth - 1) (c : acc) rest
            _ -> go depth (c : acc) rest

-- | Map every char through a super/subscript table; if any char has
-- no unicode form, fall back to @^(..)@ / @_(..)@ (or bare @^x@).
mapScript :: Map Char Char -> Text -> Text -> Text
mapScript table lit t
  | T.null t = lit
  | Just mapped <- T.foldr step (Just "") t = mapped
  | T.length t == 1 = lit <> t
  | otherwise = lit <> "(" <> t <> ")"
  where
    step c acc = T.cons <$> Map.lookup c table <*> acc

superscriptMap :: Map Char Char
superscriptMap =
  Map.fromList $
    zip "0123456789+-=()ni" "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾ⁿⁱ"

subscriptMap :: Map Char Char
subscriptMap =
  Map.fromList $
    zip "0123456789+-=()aehijklmnoprstuvx" "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ"

-- | Commands that consume brace arguments and re-emit them.
argCommands :: Map Text (Int, [Text] -> Text)
argCommands =
  Map.fromList
    [ ("text", (1, T.concat)),
      ("mathrm", (1, T.concat)),
      ("mathbf", (1, T.concat)),
      ("mathit", (1, T.concat)),
      ("mathbb", (1, T.concat)),
      ("mathcal", (1, T.concat)),
      ("operatorname", (1, T.concat)),
      ("boxed", (1, T.concat)),
      ("vec", (1, \a -> T.concat a <> "\x20D7"))
    ]

-- | Function names that read fine as plain words.
plainNames :: [Text]
plainNames =
  [ "sin", "cos", "tan", "cot", "sec", "csc",
    "arcsin", "arccos", "arctan",
    "sinh", "cosh", "tanh",
    "log", "ln", "lg", "exp",
    "lim", "max", "min", "sup", "inf",
    "gcd", "det", "dim", "mod", "deg", "arg"
  ]

symbols :: Map Text Text
symbols =
  Map.fromList
    [ -- greek
      ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"),
      ("epsilon", "ε"), ("varepsilon", "ε"), ("zeta", "ζ"), ("eta", "η"),
      ("theta", "θ"), ("vartheta", "θ"), ("iota", "ι"), ("kappa", "κ"),
      ("lambda", "λ"), ("mu", "μ"), ("nu", "ν"), ("xi", "ξ"),
      ("pi", "π"), ("rho", "ρ"), ("sigma", "σ"), ("tau", "τ"),
      ("upsilon", "υ"), ("phi", "φ"), ("varphi", "φ"), ("chi", "χ"),
      ("psi", "ψ"), ("omega", "ω"),
      ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"), ("Lambda", "Λ"),
      ("Xi", "Ξ"), ("Pi", "Π"), ("Sigma", "Σ"), ("Upsilon", "Υ"),
      ("Phi", "Φ"), ("Psi", "Ψ"), ("Omega", "Ω"),
      -- operators / relations
      ("times", "×"), ("cdot", "·"), ("div", "÷"), ("pm", "±"), ("mp", "∓"),
      ("leq", "≤"), ("le", "≤"), ("geq", "≥"), ("ge", "≥"),
      ("neq", "≠"), ("ne", "≠"), ("approx", "≈"), ("equiv", "≡"),
      ("sim", "~"), ("simeq", "≃"), ("propto", "∝"),
      ("ll", "≪"), ("gg", "≫"),
      -- arrows
      ("to", "→"), ("rightarrow", "→"), ("leftarrow", "←"),
      ("Rightarrow", "⇒"), ("Leftarrow", "⇐"),
      ("leftrightarrow", "↔"), ("Leftrightarrow", "⇔"),
      ("mapsto", "↦"), ("implies", "⇒"), ("iff", "⇔"),
      -- sets / logic
      ("in", "∈"), ("notin", "∉"), ("subset", "⊂"), ("subseteq", "⊆"),
      ("supset", "⊃"), ("supseteq", "⊇"), ("cup", "∪"), ("cap", "∩"),
      ("setminus", "∖"), ("emptyset", "∅"), ("varnothing", "∅"),
      ("forall", "∀"), ("exists", "∃"), ("neg", "¬"),
      ("land", "∧"), ("wedge", "∧"), ("lor", "∨"), ("vee", "∨"),
      -- calculus / big ops
      ("sum", "Σ"), ("prod", "∏"), ("int", "∫"), ("oint", "∮"),
      ("partial", "∂"), ("nabla", "∇"), ("infty", "∞"),
      -- misc
      ("degree", "°"), ("circ", "∘"), ("bullet", "•"), ("star", "⋆"),
      ("cdots", "⋯"), ("ldots", "…"), ("dots", "…"), ("vdots", "⋮"),
      ("angle", "∠"), ("perp", "⊥"), ("parallel", "∥"),
      ("hbar", "ℏ"), ("ell", "ℓ"), ("Re", "ℜ"), ("Im", "ℑ"),
      ("aleph", "ℵ"), ("prime", "′"),
      ("langle", "⟨"), ("rangle", "⟩"),
      ("lfloor", "⌊"), ("rfloor", "⌋"), ("lceil", "⌈"), ("rceil", "⌉"),
      -- spacing / structure: vanish
      ("left", ""), ("right", ""), ("big", ""), ("Big", ""),
      ("bigl", ""), ("bigr", ""), ("Bigl", ""), ("Bigr", ""),
      ("quad", " "), ("qquad", "  "), ("displaystyle", ""), ("limits", "")
    ]
