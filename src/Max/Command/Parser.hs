{-# LANGUAGE OverloadedStrings #-}

-- |
-- megaparsec-based parser for the @!cmd@ DSL.  The grammar is in
-- "Max.Command.Types".  Entry point is 'parseCommand'.
--
-- Returns @Right Nothing@ for messages that don't look like a command
-- at all (so the caller can pass them through to the LLM path).
-- Returns @Right (Just cmd)@ for a parsed command.  Returns @Left err@
-- when the message starts with @!@ followed by an identifier but
-- something further on is malformed — that's a real syntax error
-- we want to report back to the user.
module Max.Command.Parser
  ( parseCommand,
    parseCommandText,
  )
where

import Control.Monad (void)
import Data.Map.Strict qualified as Map
import Data.Int (Int64)
import Data.Maybe (catMaybes)
import Data.Text.Read qualified as TR
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Max.Command.Types
import Text.Megaparsec
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer qualified as L

type Parser = Parsec Void Text

-- | Entry point used by the handler.  Returns:
--
--   * @Right Nothing@        — not a command at all (no leading @!@,
--     or @!@ followed by something that isn't an identifier).
--   * @Right (Just cmd)@     — parsed successfully.
--   * @Left errorMessage@    — looks like a command but is malformed;
--     show the message back to the user.
parseCommand :: Text -> Either Text (Maybe Command)
parseCommand input
  | Just body <- shellBody input =
      let (pkgs, cmd) = splitLeadingPkgs body
       in Right (Just (Shell pkgs cmd))
  | not (looksLikeCommand input) = Right Nothing
  | otherwise = case runParser (commandP <* eof) "command" input of
      Right cmd -> Right (Just cmd)
      Left bundle -> Left (T.pack (errorBundlePretty bundle))

-- | Claude-Code-style shell escape: a bang, then whitespace, then a
-- non-empty rest.  The rest is the shell body (leading @+pkg@ tokens
-- split off by 'splitLeadingPkgs'; everything after is raw — quotes,
-- pipes, newlines, @--flags@ all verbatim).  @!verb@ with no space
-- stays the structured-command path.
shellBody :: Text -> Maybe Text
shellBody t = case T.uncons (T.dropWhile (== ' ') t) of
  Just ('!', rest) | startsWithSpace rest ->
    let body = T.strip rest in if T.null body then Nothing else Just body
  _ -> Nothing
  where
    startsWithSpace r = case T.uncons r of
      Just (c, _) -> c == ' ' || c == '\t'
      Nothing -> False

-- | Peel leading @+pkg@ tokens off a shell body: each whitespace-run
-- of the form @+name@ at the very start is a nixpkgs attribute to put
-- on PATH.  The first token that doesn't start with @+@ ends the
-- package list; everything from there on is the command, kept
-- verbatim (internal newlines and spacing preserved).  A bare @+@ or
-- empty name is skipped.
splitLeadingPkgs :: Text -> ([Text], Text)
splitLeadingPkgs = go []
  where
    go acc s =
      let s' = T.stripStart s
       in case T.uncons s' of
            Just ('+', _) ->
              let (tok, rest) = T.break isSpace s'
                  pkg = T.drop 1 tok
               in if T.null pkg
                    then go acc rest -- lone '+', ignore
                    else go (pkg : acc) rest
            _ -> (reverse acc, s')
    isSpace c = c == ' ' || c == '\t' || c == '\n' || c == '\r'

-- | Same but never returns @Right Nothing@ — for callers that already
-- know the input is meant to be a command.
parseCommandText :: Text -> Either Text Command
parseCommandText input = case parseCommand input of
  Right (Just c) -> Right c
  Right Nothing -> Left "not a command"
  Left e -> Left e

-- | Cheap pre-check: leading @!@ followed by ASCII letter.  We treat
-- everything else as not-a-command so people can still yell "！！！"
-- without triggering a parse error.
looksLikeCommand :: Text -> Bool
looksLikeCommand t = case T.uncons (T.dropWhile (== ' ') t) of
  Just ('!', rest) -> case T.uncons rest of
    Just (c, _) | isIdentStart c -> True
    _ -> False
  _ -> False
  where
    isIdentStart c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')

--------------------------------------------------------------------------------
-- megaparsec

sc :: Parser ()
sc = L.space (void (some (char ' ' <|> char '\t'))) empty empty

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

identP :: Parser Text
identP = lexeme $ do
  c <- letterChar
  cs <- many (alphaNumChar <|> char '-' <|> char '_')
  pure (T.pack (c : cs))

-- | Verb identifier, after the leading @!@.  Permits @-@/@_@ but
-- requires a letter start.
verbP :: Parser Text
verbP = do
  _ <- char '!'
  identP

-- | One value: a quoted string ("…" or '…') or a bareword.  Barewords
-- run until whitespace and may include any printable characters
-- except the flag-starting double dash (handled separately).
valueP :: Parser Text
valueP = lexeme (dquoted <|> squoted <|> bareword)
  where
    dquoted = T.pack <$> (char '"' *> manyTill escapedChar (char '"'))
    squoted = T.pack <$> (char '\'' *> manyTill anySingle (char '\''))
    bareword = T.pack <$> some (satisfy isBareword)
    isBareword c = c /= ' ' && c /= '\t' && c /= '"' && c /= '\''

    escapedChar = (char '\\' *> escape) <|> satisfy (/= '"')
    escape =
      choice
        [ '\n' <$ char 'n',
          '\t' <$ char 't',
          '\\' <$ char '\\',
          '"' <$ char '"',
          '\'' <$ char '\''
        ]

-- | A flag token: a long @--flag@ / @--flag=value@ (one entry), or a
-- short cluster @-a@ / @-dg@ where each letter is expanded to its long
-- name via 'shortFlagAlias' (short flags are boolean-only — bare
-- @--flag@ and every short flag store 'Nothing').  Returns a list so a
-- bundled short cluster becomes several flags.
--
-- A short cluster only parses when /every/ letter is a known alias;
-- otherwise it fails and 'argP' backtracks, so a negative id like @-1@
-- or free text like @-cool@ stays a positional value rather than being
-- silently eaten as flags.
flagP :: Parser [(Text, Maybe Text)]
flagP = longFlag <|> shortCluster
  where
    longFlag = fmap (: []) . try . lexeme $ do
      _ <- string "--"
      name <- T.pack <$> some (alphaNumChar <|> char '-' <|> char '_')
      mval <- optional (char '=' *> valueRaw)
      pure (name, mval)
    shortCluster = lexeme $ do
      _ <- char '-'
      cs <- some letterChar
      case traverse shortFlagAlias cs of
        Just longs -> pure [(l, Nothing) | l <- longs]
        Nothing -> fail "unknown short flag"
    -- inline value for --flag=value: same as 'valueP' but no surrounding lexeme
    valueRaw =
      choice
        [ T.pack <$> (char '"' *> manyTill escapedChar (char '"')),
          T.pack <$> (char '\'' *> manyTill anySingle (char '\'')),
          T.pack <$> some (satisfy isBareNoEq)
        ]
    isBareNoEq c = c /= ' ' && c /= '\t' && c /= '"' && c /= '\''
    escapedChar = (char '\\' *> escape) <|> satisfy (/= '"')
    escape =
      choice
        [ '\n' <$ char 'n',
          '\t' <$ char 't',
          '\\' <$ char '\\',
          '"' <$ char '"',
          '\'' <$ char '\''
        ]

-- | Short single-letter flag aliases, shared across every command.  Two
-- long flags must never share a first letter or their short forms would
-- collide; the current set is @all@\/@deny@\/@global@ → @a@\/@d@\/@g@.
-- Keep in sync with the flag names 'classify' checks.
shortFlagAlias :: Char -> Maybe Text
shortFlagAlias c = case c of
  'a' -> Just "all"
  'd' -> Just "deny"
  'g' -> Just "global"
  _ -> Nothing

-- | Either a flag token or a positional arg.  A flag token yields a
-- list ('flagP') so a bundled short cluster like @-dg@ expands to
-- several flags.
argP :: Parser (Either [(Text, Maybe Text)] Text)
argP = (Left <$> try flagP) <|> (Right <$> valueP)

-- | Top-level command parser: verb + zero-or-more args, then build the
-- concrete 'Command' from raw shape.
commandP :: Parser Command
commandP = do
  sc
  v <- verbP
  raw <-
    if v `elem` freeTextVerbs
      then -- These verbs take a literal free-text body (a persona, a
           -- note): parse the remainder as plain values so a leading
           -- @-a@- or @--flag@-looking word is kept verbatim instead of
           -- being eaten as a flag.  'classify' ignores flags for them,
           -- so we leave the flag map empty.
        (\vals -> RawArgs vals mempty) <$> many valueP
      else do
        args <- many argP
        pure (RawArgs [t | Right t <- args] (Map.fromList (concat [fs | Left fs <- args])))
  pure (classify v raw)

-- | Verbs whose arguments are a literal free-text body, not a
-- flag\/value arg list.  For these 'commandP' skips flag parsing so
-- dash-prefixed words in the text survive (see 'classify' for @persona@
-- \/ @btw@ \/ @feedback@, which join their positional words with
-- spaces).
freeTextVerbs :: [Text]
freeTextVerbs = ["persona", "btw", "feedback", "fb"]

-- | Map (verb, args) → concrete 'Command'.  Reduces the parser surface
-- to a flat set of variants the dispatcher can pattern-match on.
classify :: Text -> RawArgs -> Command
classify verb raw@(RawArgs pos flags) = case verb of
  "help" -> Help (oneArg pos)
  "grant" -> case pos of
    [target, cap]
      | Just uid <- parseUserRef target ->
          Grant uid cap ("deny" `Map.member` flags) ("global" `Map.member` flags)
    _ -> Unknown verb raw
  "revoke" -> case pos of
    [target, cap]
      | Just uid <- parseUserRef target ->
          Revoke uid cap ("global" `Map.member` flags)
    _ -> Unknown verb raw
  "perms" -> case pos of
    [] -> Perms Nothing
    [target] | Just uid <- parseUserRef target -> Perms (Just uid)
    _ -> Unknown verb raw
  "use" -> case pos of
    [] -> UseShow
    ["clear"] -> UseClear
    [g] | Just gid <- parseInt64 g, gid > 0 -> UseSet gid
    _ -> Unknown verb raw
  "status" -> case pos of
    [] -> Status
    _ -> Unknown verb raw
  "model" -> case pos of
    [] -> ModelShow
    ["list"] -> ModelList
    [name] -> ModelSet name
    _ -> Unknown verb raw -- too many args; let dispatcher complain
  "debug" -> case pos of
    [] -> DebugShow
    ["on"] -> DebugSet (Just True)
    ["off"] -> DebugSet (Just False)
    ["default"] -> DebugSet Nothing
    _ -> Unknown verb raw
  "persona" -> case pos of
    [] -> PersonaShow
    ["clear"] -> PersonaClear
    _ -> PersonaSet (T.unwords pos)
  "clear" -> if "all" `Map.member` flags then ClearAll else Clear
  "unclear" -> Unclear
  "pin" -> case pos of
    [] -> Pin Nothing
    [s] -> case parseInt64 s of
      Just n -> Pin (Just n)
      Nothing -> Unknown verb raw
    _ -> Unknown verb raw
  "unpin" -> case pos of
    [] -> Unpin UnpinReply
    ["all"] -> Unpin UnpinAll
    [s] -> case parseInt64 s of
      Just n -> Unpin (UnpinOne n)
      Nothing -> Unknown verb raw
    _ -> Unknown verb raw
  "pins" -> Pins
  "btw" -> Btw (T.unwords pos)
  "feedback" -> Feedback (T.unwords pos)
  "fb" -> Feedback (T.unwords pos)
  "ps" -> if "all" `Map.member` flags then PsAll else PsLocal
  "kill"
    | "all" `Map.member` flags -> KillAll
    | otherwise -> case pos of
        [tid] -> Kill tid
        _ -> Unknown verb raw
  "memory" -> case pos of
    [] -> MemoryList
    ["rm", s] -> case parseInt64 s of
      Just n -> MemoryRm n
      Nothing -> Unknown verb raw
    _ -> Unknown verb raw
  "sticker" -> case pos of
    [] -> StickerStats
    ["on"] -> StickerSet (Just True)
    ["off"] -> StickerSet (Just False)
    ["default"] -> StickerSet Nothing
    ["list"] -> StickerList
    ["ban", s] -> StickerBan s
    ["unban", s] -> StickerUnban s
    _ -> Unknown verb raw
  "proactive" -> case pos of
    [] -> ProactiveStatus
    ["on"] -> ProactiveSet (Just True)
    ["off"] -> ProactiveSet (Just False)
    ["default"] -> ProactiveSet Nothing
    _ -> Unknown verb raw
  "version" -> Version
  _ -> Unknown verb raw
  where
    oneArg xs = case catMaybes [Just t | t <- xs] of
      [] -> Nothing
      (t : _) -> Just t

parseInt64 :: Text -> Maybe Int64
parseInt64 t = case TR.signed TR.decimal (T.strip t) of
  Right (n, rest) | T.null rest -> Just n
  _ -> Nothing

-- | A user reference in command args: the canonical @[\@#qq]@ token
-- (what an @-mention renders as), a bare @\@qq@, or a raw QQ number.
parseUserRef :: Text -> Maybe Int64
parseUserRef t0 = case T.stripPrefix "[@#" t0 of
  Just rest -> T.stripSuffix "]" rest >>= parseInt64
  Nothing -> case T.stripPrefix "@" t0 of
    Just bare -> parseInt64 bare
    Nothing -> parseInt64 t0
