module Max.Util
  ( catchSync,
    splitReply,
    maxReplyChunks,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff)
import Effectful.Exception
  ( SomeAsyncException,
    SomeException,
    catch,
    fromException,
    throwIO,
  )

-- | Catch only synchronous exceptions; re-raise anything tagged
-- 'SomeAsyncException' so cancellation and signals propagate normally.
catchSync ::
  Eff es a ->
  (SomeException -> Eff es a) ->
  Eff es a
catchSync act h =
  act `catch` \e ->
    case fromException e :: Maybe SomeAsyncException of
      Just _ -> throwIO e
      Nothing -> h e

-- | Split a reply into separate outgoing messages on blank-line
-- paragraph breaks — QQ chats read multiple short messages, not one
-- wall of text.  Blank lines inside ``` fences do NOT split (the
-- style guide tells the model code blocks are free-form).  Capped at
-- 'maxReplyChunks': overflow paragraphs are folded into the last
-- chunk so a rambling reply can't flood the chat.
splitReply :: Text -> [Text]
splitReply body = case capChunks (go False [] (T.lines body)) of
  [] -> [T.strip body]
  cs -> cs
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
    isFence l = "```" `T.isPrefixOf` T.stripStart l

maxReplyChunks :: Int
maxReplyChunks = 5

capChunks :: [Text] -> [Text]
capChunks xs
  | length xs <= maxReplyChunks = xs
  | otherwise =
      take (maxReplyChunks - 1) xs
        <> [T.intercalate "\n\n" (drop (maxReplyChunks - 1) xs)]
