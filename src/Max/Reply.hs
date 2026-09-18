-- | Pure reply planning: extract tables, convert LaTeX to Unicode, and split
-- at blank lines or [split] outside code fences. Rendering and sending belong
-- to the caller; the sender applies maxChunks across the logical reply.
module Max.Reply
  ( Chunk (..),
    CodeBlock (..),
    chunkSource,
    planReply,
    maxChunks,
    stripHallucinatedTokens,
    latexToUnicode,
    ReplyPiece (..),
    parseReplyTokens,
    readyPrefix,
    dedupeImagePieces,
  )
where

import Control.Applicative ((<|>))
import Data.Char (isAlpha, isAscii, isDigit, isSpace)
import Data.List (dropWhileEnd, foldl', unsnoc)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Max.Util (readIntegral)

-- | One outgoing message.  'TableChunk' and 'CodeChunk' carry source the
-- caller renders to an image, falling back to text if rendering fails.
data Chunk
  = TextChunk !Text
  | TableChunk !Text
  | CodeChunk !CodeBlock
  deriving stock (Show, Eq)

-- | A fenced code block, kept in all three forms the pipeline needs at
-- once because each consumer wants a different one and none can recover
-- the others: the info string picks the highlighter, the body is what a
-- text-only endpoint should receive (QQ has no monospace, but bare
-- backticks there are just noise), and the source is what the model must
-- read back as its own words.
data CodeBlock = CodeBlock
  { cbLang :: !(Maybe Text),
    cbBody :: !Text,
    cbSource :: !Text
  }
  deriving stock (Show, Eq)

-- | The text a chunk was planned from — what should go into the
-- bot's own history (the model should see the table it wrote, not
-- an image), and the fallback when rendering fails.
chunkSource :: Chunk -> Text
chunkSource = \case
  TextChunk t -> t
  TableChunk t -> t
  CodeChunk cb -> cb.cbSource

-- | Plan outgoing chunks. Blank or [split]-only input produces no chunks;
-- do not restore the raw input when planning returns an empty list.
planReply :: Text -> [Chunk]
planReply body = capChunks (concatMap explode (splitBlocks body))
  where
    explode (TableChunk t) = [TableChunk t]
    -- Deliberately not through 'latexToUnicode': inside a fence, @\alpha@
    -- is somebody's identifier, not a symbol waiting to be prettified.
    explode c@(CodeChunk _) = [c]
    explode (TextChunk t) = map TextChunk (splitChunks (latexToUnicode t))

-- | Maximum messages per logical reply. Excess chunks merge into the last
-- message; that merge retains only the first reply target in the tail.
maxChunks :: Int
maxChunks = 10

-- | Merge excess chunks into the final message. Tables in the tail become
-- markdown; only its first reply target survives placeholder parsing.
capChunks :: [Chunk] -> [Chunk]
capChunks cs
  | length cs <= maxChunks = cs
  | otherwise = keep <> [TextChunk (T.intercalate "\n\n" (map chunkSource spill))]
  where
    (keep, spill) = splitAt (maxChunks - 1) cs

--------------------------------------------------------------------------------
-- Outbound placeholders: [reply#<id>] quotes, [sticker#<id>] stickers,
-- [image#<id>] resends, [face#<id>] QQ faces.

-- | A parsed span of one planned text chunk.  'PieceText' still holds
-- raw @\@\<qq\>@ spans — mention conversion happens later, per piece.
data ReplyPiece
  = PieceText !Text
  | PieceSticker !Int64
  | -- | A @[sticker#\<描述文本\>]@ where the id slot holds prose: the
    -- model copied the caption instead of the number.  Resolved
    -- against sticker captions at send time; unresolvable ones are
    -- dropped, never leaked as text.
    PieceStickerDesc !Text
  | -- | A @[image#\<canonical_message_id\>]@ resend of a stored group
    -- image, or @[image#\<canonical_message_id\>.\<seg\>]@ for one
    -- picture of a message carrying several.  'Nothing' is every image
    -- on that message, which is what the bare form has always meant.
    PieceImage !Int64 !(Maybe Int)
  | -- | A @[face#\<id\>]@ QQ built-in face — the same form
    -- 'OneBot.Segment.renderPlainText' shows inbound faces in.
    PieceFace !Int
  deriving stock (Show, Eq)

-- | Parse reply, sticker, image and face placeholders in one chunk.
-- The first reply token selects the target; all reply tokens are removed.
-- Sticker captions are accepted but ignored; image handles may select a segment.
-- Malformed tokens remain text. Max.ReplySend resolves IDs to outbound content.
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
            Just (TokStickerDesc d, rest') ->
              let (mrid, ps) = go rest'
               in (mrid, prepend before (PieceStickerDesc d : ps))
            Just (TokImage n seg, rest') ->
              let (mrid, ps) = go rest'
               in (mrid, prepend before (PieceImage n seg : ps))
            Just (TokFace n, rest') ->
              let (mrid, ps) = go rest'
               in (mrid, prepend before (PieceFace n : ps))
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

data Token
  = TokReply !Int64
  | TokSticker !Int64
  | TokStickerDesc !Text
  | TokImage !Int64 !(Maybe Int)
  | TokFace !Int

matchToken :: Text -> Maybe (Token, Text)
matchToken t =
  (do rest <- T.stripPrefix "[reply#" t; (n, r) <- signedTokenClose rest; pure (TokReply n, r))
    -- Pre-rename reply opener, kept readable for the same reason the
    -- sticker one is: history and the model's own past lines carry it.
    <|> (do rest <- T.stripPrefix "[↩#" t; (n, r) <- signedTokenClose rest; pure (TokReply n, r))
    <|> (do rest <- T.stripPrefix "[image#" t; (n, seg, r) <- segmentedTokenClose rest; pure (TokImage n seg, r))
    <|> (do rest <- T.stripPrefix "[face#" t; (n, r) <- tokenClose rest; pure (TokFace (fromIntegral n), r))
    <|> (do rest <- T.stripPrefix "[sticker#" t; (n, r) <- tokenClose rest; pure (TokSticker n, r))
    -- Pre-rename sticker opener: old rows (and models echoing them)
    -- still carry it.
    <|> (do rest <- T.stripPrefix "[表情包#" t; (n, r) <- tokenClose rest; pure (TokSticker n, r))
    -- The id slot holding prose instead of digits: the model copied
    -- the caption out of the display form ([sticker#42: 柴犬瘫地]) and
    -- lost the number.  Accept it as a caption reference — the send
    -- layer resolves or drops it; the one thing that must not happen
    -- is the marker going out as literal text.
    <|> (do rest <- T.stripPrefix "[sticker#" t; (d, r) <- descClose rest; pure (TokStickerDesc d, r))
    <|> (do rest <- T.stripPrefix "[表情包#" t; (d, r) <- descClose rest; pure (TokStickerDesc d, r))
  where
    -- One tolerant closer for every verb: digits, then ']' or a
    -- ': description]' tail, then an optional display-attribute
    -- group "(…)" glued after the bracket.  Models are taught to
    -- write the bare [verb#id], but echoing the full inbound display
    -- form ("[video#7407: 首帧…](29秒)") must still act — only the id
    -- is trusted, decorations are consumed and dropped.
    tokenClose :: Text -> Maybe (Int64, Text)
    tokenClose s = do
      (n, rest) <- unsignedId s
      after <- closer rest
      pure (n, after)
    -- Canonical message ids are positive, but the sign is still accepted:
    -- history written before ADR 004 spelled foreign-platform messages with
    -- a minted negative, and a model echoing one back must not have the
    -- token leak into the group as literal text.  It simply won't resolve.
    signedTokenClose :: Text -> Maybe (Int64, Text)
    signedTokenClose s = do
      (n, rest) <- signedId s
      after <- closer rest
      pure (n, after)
    -- Media addresses one picture of a message: "[image#4711.2]" is the
    -- (canonical_message_id, seg_index) primary key of 'message_images',
    -- rendered verbatim.  The bare form still means every image on that
    -- message.
    segmentedTokenClose :: Text -> Maybe (Int64, Maybe Int, Text)
    segmentedTokenClose s = do
      (n, rest) <- signedId s
      let (seg, rest') = case T.stripPrefix "." rest of
            Just afterDot | (ds, r) <- T.span isDigit afterDot, not (T.null ds) ->
              (readIntegral ds, r)
            _ -> (Nothing, rest)
      after <- closer rest'
      pure (n, seg, after)

    unsignedId s =
      let (digits, rest) = T.span isDigit s
       in if T.null digits then Nothing else (,rest) <$> readIntegral digits
    signedId s =
      let (sign, unsigned) = case T.uncons s of
            Just ('-', unsignedRest) -> ("-", unsignedRest)
            _ -> ("", s)
          (digits, rest) = T.span isDigit unsigned
       in if T.null digits then Nothing else (,rest) <$> readIntegral (sign <> digits)
    closer rest = dropAttrGroup <$> case T.uncons rest of
      Just (']', r) -> Just r
      Just (':', r') -> case T.breakOn "]" r' of
        (_, close) | not (T.null close) -> Just (T.drop 1 close)
        _ -> Nothing
      -- Accept EOF as the close of a complete numeric token. Streaming retains
      -- unfinished placeholders, so an in-flight partial ID cannot reach this branch.
      -- Description tokens still require an explicit closing bracket.
      Nothing -> Just ""
      _ -> Nothing
    -- Caption text in the id slot: short, single-line, no nested
    -- bracket.  Deliberately narrow — anything wider risks eating a
    -- legitimate "[...]" prose span that happens to follow the word
    -- sticker.
    descClose s = case T.breakOn "]" s of
      (d0, close)
        | not (T.null close),
          d <- T.strip d0,
          not (T.null d),
          T.length d <= 60,
          not (signedDigits d),
          not (T.any (\c -> c == '\n' || c == '[') d) ->
            Just (d, dropAttrGroup (T.drop 1 close))
      _ -> Nothing
    signedDigits d =
      let unsigned = fromMaybe d (T.stripPrefix "-" d)
       in not (T.null unsigned) && T.all isDigit unsigned
    -- "](29秒)" → the paren group is display metadata, never content;
    -- swallow it so an echoed token doesn't leak "(29秒)" as text.
    dropAttrGroup r = case T.stripPrefix "(" r of
      Just r' -> case T.breakOn ")" r' of
        (_, close) | not (T.null close) -> T.drop 1 close
        _ -> r
      Nothing -> r

-- | Remove tool-call-looking bracket spans a model hallucinated into
-- its reply — the observed failure shape is a tool name in brackets,
-- e.g. @[find_stickers query="无语"]@.  A span is dropped when it
-- opens with an ASCII identifier, has whitespace after it, and
-- carries a '=' or quote — no legitimate grammar token or prose form
-- looks like that.  Code fences are exempt (bracket-heavy code like
-- @[n | n == 0]@ must survive verbatim).
stripHallucinatedTokens :: Text -> Text
stripHallucinatedTokens body = T.intercalate "\n" (go False (T.lines body))
  where
    go _ [] = []
    go inFence (l : rest)
      | isFence l = l : go (not inFence) rest
      | inFence = l : go inFence rest
      | otherwise = scrub l : go inFence rest
    scrub line = case T.breakOn "[" line of
      (before, rest)
        | T.null rest -> line
        | otherwise ->
            let inner = T.drop 1 rest
             in case T.breakOn "]" inner of
                  (content, close)
                    | not (T.null close) && looksToolCall content ->
                        before <> scrub (T.drop 1 close)
                  _ -> before <> "[" <> scrub inner
    looksToolCall c =
      let (w, r) = T.span (\ch -> isAlpha ch && isAscii ch || ch == '_') c
       in not (T.null w)
            && maybe False (isSpace . fst) (T.uncons r)
            && T.any (\ch -> ch `elem` ("=\"“”" :: String)) c

-- | Deduplicate image tokens across chunks using the returned seen-set.
-- A whole-message image token subsumes later segment tokens for that message;
-- a segment token does not subsume other segments or the whole message.
dedupeImagePieces :: Set (Int64, Maybe Int) -> [ReplyPiece] -> (Set (Int64, Maybe Int), [ReplyPiece])
dedupeImagePieces = go
  where
    go seen [] = (seen, [])
    go seen (PieceImage m seg : rest)
      | (m, seg) `Set.member` seen || (m, Nothing) `Set.member` seen = go seen rest
      | otherwise =
          let (seen', rest') = go (Set.insert (m, seg) seen) rest
           in (seen', PieceImage m seg : rest')
    go seen (p : rest) =
      let (seen', rest') = go seen rest
       in (seen', p : rest')

--------------------------------------------------------------------------------
-- Stage 1: carve out markdown tables and fenced code.

-- | Split fenced code and GFM tables. Tables require a header and separator;
-- table-like lines inside fences remain code. Unterminated fences stay text so
-- an incomplete streamed block is not published as a finished image.
splitBlocks :: Text -> [Chunk]
splitBlocks body = go [] (T.lines body)
  where
    go acc [] = flushText acc []
    go acc (l : rest)
      | Just lang <- fenceInfo l,
        Just (block, rest') <- takeFence l lang rest =
          flushText acc (CodeChunk block : go [] rest')
      | isFence l = flushText acc [TextChunk (T.intercalate "\n" (l : rest))]
      | Just (tbl, rest') <- takeTable (l : rest) =
          flushText acc (TableChunk (T.intercalate "\n" tbl) : go [] rest')
      | otherwise = go (l : acc) rest
    flushText acc more =
      let t = T.strip (T.intercalate "\n" (reverse acc))
       in if T.null t then more else TextChunk t : more

-- | Consume up to and including the closing fence.  'Nothing' when the
-- block never closes, which leaves the opener to be treated as text.
takeFence :: Text -> Maybe Text -> [Text] -> Maybe (CodeBlock, [Text])
takeFence opener lang rest = case break isFence rest of
  (_, []) -> Nothing
  (bodyLines, closer : rest') ->
    Just
      ( CodeBlock
          { cbLang = lang,
            cbBody = T.intercalate "\n" (trimBlankEdges bodyLines),
            cbSource = T.intercalate "\n" ((opener : bodyLines) <> [closer])
          },
        rest'
      )
  where
    trimBlankEdges = dropWhileEnd isBlankLine . dropWhile isBlankLine

isBlankLine :: Text -> Bool
isBlankLine = T.null . T.strip

-- | The info string of a fence opener — @Just "haskell"@ for
-- @\`\`\`haskell@, @Just ""@ becoming 'Nothing' for a bare fence.  A
-- language is a hint to the highlighter, never a gate: an untagged block
-- is still a code block and still becomes a picture, it just renders
-- unhighlighted.
fenceInfo :: Text -> Maybe (Maybe Text)
fenceInfo l
  | isFence l = Just (nonBlankText (T.takeWhile (not . isSpace) (T.dropWhile (== '`') (T.stripStart l))))
  | otherwise = Nothing
  where
    nonBlankText t = if T.null (T.strip t) then Nothing else Just (T.toLower (T.strip t))

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
-- Stage 3: [split]-marker split (fence-aware).

-- | The explicit chunk boundary the model may write in addition to
-- blank lines.  A marker-only regime was tried (v0.2.7) and reverted:
-- weak models rarely emit it — deliberate tokens need instruction-
-- following, while paragraph breaks come free with how models write.
splitMarker :: Text
splitMarker = "[split]"

-- | Split on blank lines AND 'splitMarker' occurrences, both outside
-- code fences (fenced content is kept verbatim).  Blank lines are
-- the workhorse: models produce paragraph breaks naturally, so even
-- weak ones get chat-sized messages for free.  The marker is the
-- explicit override for what a blank line can't express — mid-line
-- splits, a sticker on its own message.  Empty chunks (blank-line
-- runs, trailing markers) are dropped.
splitChunks :: Text -> [Text]
splitChunks body = filter (not . T.null) (map T.strip (go False [] (T.lines body)))
  where
    go _ acc [] = [emit acc]
    go inFence acc (l : rest)
      | isFence l = go (not inFence) (l : acc) rest
      | inFence = go inFence (l : acc) rest
      | isBlank l = emit acc : go False [] rest
      | splitMarker `T.isInfixOf` l =
          case T.splitOn splitMarker l of
            -- 'unsnoc' is what makes the split total: the marker guarantees
            -- at least two pieces, and the type no longer takes that on faith.
            firstP : more
              | Just (mids, lastP) <- unsnoc more ->
                  [emit (firstP : acc)] <> mids <> go False [lastP] rest
            _ -> go inFence (l : acc) rest
      | otherwise = go inFence (l : acc) rest
    emit acc = T.intercalate "\n" (reverse acc)
    isBlank = T.null . T.strip


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
    go depth acc t = case T.uncons t of
      Nothing -> (T.pack (reverse acc), "")
      Just ('{', rest) -> go (depth + 1) ('{' : acc) rest
      Just ('}', rest)
        | depth == 0 -> (T.pack (reverse acc), rest)
        | otherwise -> go (depth - 1) ('}' : acc) rest
      Just (c, rest) -> go depth (c : acc) rest

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

-- | Preserve the exact input while releasing completed paragraphs or plain
-- prose sentences. Keep markup intact and avoid sending each short sentence
-- as a separate message; the sender also enforces the whole-reply chunk limit.
readyPrefix :: Text -> (Text, Text)
readyPrefix acc
  | T.null safe = T.splitAt (proseBoundary acc) acc
  | odd (length (filter isFence (T.lines safe))) = ("", acc)
  | otherwise = (safe, held)
  where
    -- breakOnEnd keeps the separator on the left, so the boundary
    -- lands after the blank line rather than before it.
    (safe, held) = T.breakOnEnd "\n\n" acc

proseBoundary :: Text -> Int
proseBoundary text
  | T.any (`elem` ("\n`~[](){}<>|$\\/*_#=“”‘’「」『』\"" :: String)) text = 0
  | otherwise = foldl' boundary 0 (zip3 [1 ..] chars (drop 1 chars))
  where
    chars = T.unpack text
    boundary previous (offset, current, next)
      | offset >= 48 && sentenceEnd current next = offset
      | offset >= 240 && (isSpace current || (cjk current && cjk next)) = offset
      | otherwise = previous
    sentenceEnd current next =
      current `elem` ("。！？" :: String)
        || (current `elem` (".!?" :: String) && isSpace next)
    cjk c = c >= '\x3400' && c <= '\x9fff'
