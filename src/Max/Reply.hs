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
--   3. splits the remaining text into messages at blank lines and
--      explicit @[split]@ markers (code fences never split).
--
-- No cap on chunk count: the system prompt already pushes for short
-- multi-chunk replies, and every chunk carries its own optional
-- [↩#<id>] quote — folding tails together broke those.
--
-- Everything here is pure; the effectful part (typst rendering,
-- sending) lives with the caller.
module Max.Reply
  ( Chunk (..),
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
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
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

-- | Plan one blob of model-authored text into outgoing messages.
--
-- __Empty when nothing survives planning__ — a blank body, or one that
-- was nothing but @[split]@ markers.  The second case is not
-- hypothetical: streaming releases up to the last blank line, so a
-- reply or narration ending in @"…\\n\\n[split]"@ hands the sender
-- exactly @"[split]"@ as its remainder.  This used to fall back to
-- @[TextChunk (T.strip body)]@ for an empty plan, which resurrected
-- that marker verbatim and put it in the group as a message reading
-- @[split]@ and nothing else — production did this seven times in the
-- two days after v0.9.1 taught 'Max.Effects.Agent.sendNarration' to
-- plan, because the planner it was pointed at handed the marker back.
--
-- "Nothing to send" is a real answer, and both callers already read
-- @[]@ that way.
planReply :: Text -> [Chunk]
planReply body = capChunks (concatMap explode (splitTables body))
  where
    explode (TableChunk t) = [TableChunk t]
    explode (TextChunk t) = map TextChunk (splitChunks (latexToUnicode t))

-- | Ceiling on how many messages one reply may become.
--
-- 'splitChunks' breaks on every blank line and has no natural bound, so
-- one runaway generation becomes that many QQ messages — and the sender
-- paces them ~2s apart, so it is also that many seconds of the bot
-- talking over everybody.  A model that echoed its own context back
-- once turned into 26 messages spread over 54 seconds.
--
-- __Deliberately far above ordinary use.__  A 5-chunk cap existed once
-- and was removed in v0.2.7 for a good reason: folding the tail
-- together breaks per-chunk @[↩#id]@ quotes, since 'parseReplyTokens'
-- keeps only the first quote in a chunk and strips the rest.  That
-- tradeoff is still real, so the ceiling sits where only pathological
-- output reaches it rather than where deliberate multi-part replies do
-- — this is a safety bound on how long the bot may monopolise a group,
-- not a formatting rule.  Normal replies run one to three chunks; a
-- model using @[split]@ on purpose does not approach ten.
maxChunks :: Int
maxChunks = 10

-- | Merge everything past the cap into the last message rather than
-- dropping it — loud but bounded beats truncated, and the bot's own
-- history still records what it said.  A table caught in the tail
-- degrades to its markdown source, the same fallback a failed render
-- already takes; a second @[↩#id]@ in the tail is lost, which is the
-- cost 'maxChunks' documents.
capChunks :: [Chunk] -> [Chunk]
capChunks cs
  | length cs <= maxChunks = cs
  | otherwise = keep <> [TextChunk (T.intercalate "\n\n" (map chunkSource spill))]
  where
    (keep, spill) = splitAt (maxChunks - 1) cs

--------------------------------------------------------------------------------
-- Outbound placeholders: [↩#<id>] quotes, [sticker#<id>] stickers,
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
  | -- | A @[image#\<message_id\>]@ resend of a stored group image.
    PieceImage !Int64
  | -- | A @[face#\<id\>]@ QQ built-in face — the same form
    -- 'OneBot.Segment.renderPlainText' shows inbound faces in.
    PieceFace !Int
  deriving stock (Show, Eq)

-- | Pull the reply/sticker/image placeholders out of one planned text
-- chunk.
--
--   * @[↩#\<id\>]@ — a quote.  The first one becomes the chunk's reply
--     target ('fst' of the result); every @[↩#…]@ token is stripped
--     from the text regardless of position.
--   * @[sticker#\<id\>]@ — a sticker, becomes a 'PieceSticker'.  The
--     inbound display form @[sticker#\<id\>: …]@ is accepted too (the
--     trailing caption is ignored) so echoing what was seen still sends.
--   * @[image#\<message_id\>]@ — resend a stored group image, becomes a
--     'PieceImage' (the same handle the model reads inbound).
--   * @[face#\<id\>]@ — a QQ built-in face, becomes a 'PieceFace'.
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
            Just (TokStickerDesc d, rest') ->
              let (mrid, ps) = go rest'
               in (mrid, prepend before (PieceStickerDesc d : ps))
            Just (TokImage n, rest') ->
              let (mrid, ps) = go rest'
               in (mrid, prepend before (PieceImage n : ps))
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

data Token = TokReply !Int64 | TokSticker !Int64 | TokStickerDesc !Text | TokImage !Int64 | TokFace !Int

matchToken :: Text -> Maybe (Token, Text)
matchToken t =
  (do rest <- T.stripPrefix "[↩#" t; (n, r) <- signedTokenClose rest; pure (TokReply n, r))
    <|> (do rest <- T.stripPrefix "[image#" t; (n, r) <- signedTokenClose rest; pure (TokImage n, r))
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
    tokenClose s =
      let (digits, rest) = T.span isDigit s
       in if T.null digits
            then Nothing
            else do
              n <- readInt64 digits
              after <- case T.uncons rest of
                Just (']', r) -> Just r
                Just (':', r') -> case T.breakOn "]" r' of
                  (_, close) | not (T.null close) -> Just (T.drop 1 close)
                  _ -> Nothing
                _ -> Nothing
              pure (n, dropAttrGroup after)
    -- Foreign-platform compatibility message ids come from a dedicated
    -- negative namespace.  They are still valid conversation-scoped handles,
    -- unlike sticker/face ids, which remain positive-only.
    signedTokenClose s =
      let (sign, unsigned) = case T.uncons s of
            Just ('-', unsignedRest) -> ("-", unsignedRest)
            _ -> ("", s)
          (digits, rest) = T.span isDigit unsigned
       in if T.null digits
            then Nothing
            else do
              n <- readInt64 (sign <> digits)
              after <- case T.uncons rest of
                Just (']', r) -> Just r
                Just (':', r') -> case T.breakOn "]" r' of
                  (_, close) | not (T.null close) -> Just (T.drop 1 close)
                  _ -> Nothing
                _ -> Nothing
              pure (n, dropAttrGroup after)
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

readInt64 :: Text -> Maybe Int64
readInt64 s = case TR.signed TR.decimal s of
  Right (n, "") -> Just n
  _ -> Nothing

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

-- | Drop duplicate @[image#\<id\>]@ resend tokens, keeping the first.
-- A multi-image message renders inbound as several markers carrying
-- the *same* message id, and each outbound token resends *all* of
-- that message's images — echoing the markers verbatim would send
-- N×N images.  The seen-set threads across chunks so a duplicate in
-- a later paragraph is dropped too.
dedupeImagePieces :: Set Int64 -> [ReplyPiece] -> (Set Int64, [ReplyPiece])
dedupeImagePieces = go
  where
    go seen [] = (seen, [])
    go seen (PieceImage m : rest)
      | m `Set.member` seen = go seen rest
      | otherwise =
          let (seen', rest') = go (Set.insert m seen) rest
           in (seen', PieceImage m : rest')
    go seen (p : rest) =
      let (seen', rest') = go seen rest
       in (seen', p : rest')

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
            (firstP : more) ->
              let mids = init more
                  lastP = last more
               in [emit (firstP : acc)] <> mids <> go False [lastP] rest
            [] -> go inFence (l : acc) rest -- unreachable: splitOn is non-empty
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

-- | Split accumulated streaming text into the part that is safe to
-- send now and the part that must keep growing.
--
-- @fst <> snd == input@ exactly, so the caller can send the prefix and
-- hand the rest to 'planReply' at the end without the two disagreeing
-- about where a chunk began.
--
-- Safe means "no later byte can change how this splits":
--
--   * only up to the last blank line — the trailing paragraph may
--     still grow, and a single-paragraph reply therefore never emits
--     early.  That is also what keeps @[silence]@ from being sent
--     before we know the reply was only that;
--   * nothing while a code fence is open, since a blank line inside
--     one is not a chunk boundary.
--
-- Both failure directions are deliberate: not splitting costs latency,
-- splitting wrongly sends a fragment that can't be recalled.  Anything
-- uncertain therefore holds.
readyPrefix :: Text -> (Text, Text)
readyPrefix acc
  | T.null safe = ("", acc)
  | odd (length (filter isFence (T.lines safe))) = ("", acc)
  | otherwise = (safe, held)
  where
    -- breakOnEnd keeps the separator on the left, so the boundary
    -- lands after the blank line rather than before it.
    (safe, held) = T.breakOnEnd "\n\n" acc
