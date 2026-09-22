-- | Names in the read-only @/chat@ view. A conversation's media are named by
-- what the prompt already shows: @[image#123.0]@ is @/chat/123.0.jpg@, and a
-- @[file:a.pdf]@ on line @#456@ is @/chat/456-a.pdf@. Every name is one safe
-- path component.
module Max.Sandbox.Chat
  ( ChatKind (..),
    chatRoot,
    chatMediaName,
    chatFileNames,
    validChatName,
  )
where

import Data.ByteString qualified as BS
import Data.Char (isAsciiLower, isControl, isDigit)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

data ChatKind = ChatImage | ChatVideo
  deriving stock (Show, Eq)

chatRoot :: Text
chatRoot = "/chat"

-- | @[image#123.0]@ becomes @123.0.jpg@: the handle plus the stored type.
chatMediaName :: ChatKind -> Int64 -> Int -> Maybe Text -> Text
chatMediaName kind message segment mime = tshow message <> "." <> tshow segment <> "." <> extension kind mime

-- | Files carry their message id and original name. A message with several
-- files numbers them in catalog order (@456.0-a.pdf@, @456.1-b.pdf@).
chatFileNames :: Int64 -> [Text] -> [Text]
chatFileNames message = \case
  [single] -> [named Nothing single]
  names -> zipWith (named . Just) [0 :: Int ..] names
  where
    named index original = tshow message <> maybe "" (("." <>) . tshow) index <> "-" <> sanitize original

-- | One path component, no control characters, no leading dot, and within
-- one filesystem name. Every name above satisfies this by construction.
validChatName :: Text -> Bool
validChatName name =
  not (T.null name)
    && not ("." `T.isPrefixOf` name)
    && utf8Length name <= 255
    && T.all (\c -> c /= '/' && not (isControl c)) name

extension :: ChatKind -> Maybe Text -> Text
extension kind mime = case T.toLower <$> mime of
  Just "image/jpeg" -> "jpg"
  Just "image/jpg" -> "jpg"
  Just "video/quicktime" -> "mov"
  Just "video/x-matroska" -> "mkv"
  Just value
    | Just subtype <- T.stripPrefix (prefix kind) value,
      not (T.null subtype),
      T.length subtype <= 8,
      T.all (\c -> isAsciiLower c || isDigit c) subtype ->
        subtype
  _ -> "bin"
  where
    prefix ChatVideo = "video/"
    prefix ChatImage = "image/"

-- Display names come from other people's clients. Keep them readable, but
-- make them one safe path component and leave room for the message prefix.
sanitize :: Text -> Text
sanitize raw = truncateName 200 (if T.null cleaned then "file" else cleaned)
  where
    cleaned = T.strip (T.map (\c -> if c == '/' || c == '\\' || isControl c then '_' else c) raw)

truncateName :: Int -> Text -> Text
truncateName limit name
  | utf8Length name <= limit = name
  | otherwise = takeUtf8 (limit - utf8Length suffix) stem <> suffix
  where
    (stem, suffix) = case T.breakOnEnd "." name of
      (before, after)
        | T.length before > 1,
          not (T.null after),
          T.length after <= 16 ->
            (T.dropEnd 1 before, "." <> after)
      _ -> (name, "")

takeUtf8 :: Int -> Text -> Text
takeUtf8 limit = T.pack . go 0 . T.unpack
  where
    go _ [] = []
    go used (c : rest)
      | used + width > limit = []
      | otherwise = c : go (used + width) rest
      where
        width = utf8Length (T.singleton c)

utf8Length :: Text -> Int
utf8Length = BS.length . TE.encodeUtf8

tshow :: (Show a) => a -> Text
tshow = T.pack . show
