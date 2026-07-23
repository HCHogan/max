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

-- | A @--flag@ or @--flag=value@.  Bare @--flag@ stores 'Nothing'.
flagP :: Parser (Text, Maybe Text)
flagP = lexeme $ do
  _ <- string "--"
  name <- T.pack <$> some (alphaNumChar <|> char '-' <|> char '_')
  mval <- optional (char '=' *> valueRaw)
  pure (name, mval)
  where
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

-- | Either a flag or a positional arg.
argP :: Parser (Either (Text, Maybe Text) Text)
argP = (Left <$> try flagP) <|> (Right <$> valueP)

-- | Top-level command parser: verb + zero-or-more args, then build the
-- concrete 'Command' from raw shape.
commandP :: Parser Command
commandP = do
  sc
  v <- verbP
  args <- many argP
  let pos = [t | Right t <- args]
      flags = Map.fromList [(n, mv) | Left (n, mv) <- args]
      raw = RawArgs pos flags
  pure (classify v raw)

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
