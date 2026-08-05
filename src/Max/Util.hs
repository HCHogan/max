module Max.Util
  ( catchSync,
    trySync,
    trySyncIO,
    withBinaryTempFile,
    withTempDirectory,
    tshow,
    encodeText,
    readIntegral,
  )
where

import Control.Exception qualified as CE
import Control.Monad (void)
import Data.Aeson (ToJSON, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Effectful (Eff)
import Effectful.Exception
  ( SomeAsyncException,
    SomeException,
    catch,
    fromException,
    throwIO,
  )
import System.Directory
  ( createDirectory,
    getTemporaryDirectory,
    removeFile,
    removePathForcibly,
  )
import System.IO (Handle, hClose, openBinaryTempFile)

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

-- | 'try'-shaped 'catchSync': synchronous exceptions come back as
-- 'Left', async-tagged ones (cancellation, shutdown) keep flying.
trySync :: Eff es a -> Eff es (Either SomeException a)
trySync act = (Right <$> act) `catchSync` (pure . Left)

-- | IO-level sibling of 'catchSync' for the error-to-'Left' pattern:
-- like @try \@SomeException@, but anything tagged 'SomeAsyncException'
-- (timeouts, 'Max.Tasks.TaskCancelled', shutdown) is re-raised instead
-- of being surfaced as a 'Left'.  Use this instead of a bare @try@
-- around blocking calls (HTTP etc.), otherwise cancellation delivered
-- mid-call gets swallowed into an error value.
trySyncIO :: IO a -> IO (Either SomeException a)
trySyncIO act =
  (Right <$> act) `CE.catch` \e ->
    case fromException e :: Maybe SomeAsyncException of
      Just _ -> CE.throwIO e
      Nothing -> pure (Left e)

-- | A unique binary temp file whose handle and path are owned by the
-- callback's scope.  Cleanup is idempotent, so callers may close the handle
-- before handing the path to another process, or rename the path as their
-- commit step.  Synchronous failures and asynchronous cancellation both run
-- the finalizer.
withBinaryTempFile ::
  FilePath ->
  String ->
  (FilePath -> Handle -> IO a) ->
  IO a
withBinaryTempFile dir template use =
  CE.bracket
    (openBinaryTempFile dir template)
    (\(path, handle) -> ignoreIO (hClose handle) >> ignoreIO (removeFile path))
    (uncurry use)

-- | Give one conversion a private temporary directory and remove the entire
-- workspace afterwards.  Keeping all derived output beside the input avoids
-- a trail of per-file cleanup actions that can be skipped by cancellation.
withTempDirectory :: String -> (FilePath -> IO a) -> IO a
withTempDirectory template = CE.bracket acquire (ignoreIO . removePathForcibly)
  where
    acquire = do
      root <- getTemporaryDirectory
      (seed, handle) <- openBinaryTempFile root template
      let discardSeed = ignoreIO (hClose handle) >> ignoreIO (removeFile seed)
      ( do
          hClose handle
          removeFile seed
          createDirectory seed
          pure seed
        )
        `CE.onException` discardSeed

ignoreIO :: IO a -> IO ()
ignoreIO action = void (CE.try @CE.IOException action)

-- | @show@ into 'Text'.  Six modules had grown a private copy of this line.
tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- | JSON into 'Text', for the columns and payloads that store rendered JSON
-- rather than a @jsonb@ value.
encodeText :: (ToJSON a) => a -> Text
encodeText = TE.decodeUtf8 . LBS.toStrict . encode

-- | Parse a whole 'Text' as one signed integer, or nothing.  Deliberately
-- stricter than @reads@ on a 'String': no surrounding whitespace, no
-- parenthesised negatives, no trailing junk — every caller is reading an id
-- it wrote itself, and a partial parse there is a defect, not a value.
readIntegral :: (Integral a) => Text -> Maybe a
readIntegral raw = case TR.signed TR.decimal raw of
  Right (value, "") -> Just value
  _ -> Nothing
