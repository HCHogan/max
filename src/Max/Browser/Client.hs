-- | Host-owned browser sessions and transport. No model can supply a
-- session id, launch proxy, or cross-conversation registry through this API.
module Max.Browser.Client (runBrowserWithRegistry) where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Monad (void, when)
import Data.Aeson
  ( Key,
    KeyValue ((.=)),
    Value,
    decodeStrict,
    object,
    withObject,
    (.:),
  )
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as T (isInfixOf, length, pack, take)
import Data.Text.Encoding qualified as TE (encodeUtf8)
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Max.Browser.Error
  ( BrowserErrorKind (..),
    browserErrorKind,
    renderBrowserError,
  )
import Max.Browser.Registry
  ( BrowserRegistry,
    BrowserScope,
    browserScopeIsTask,
    callBrowserTool,
    getCamoSession,
    setCamoSession,
    takeBrowserRestore,
    withBrowserSession,
  )
import Max.Browser.View
  ( BrowserBudget (BrowserBudget),
    browserView,
  )
import Max.Effects.Browser
  ( Browser,
    BrowserOperation (..),
    SessionMethod (..),
    runBrowser,
  )
import Max.MCP.Client (mcpTextContent)

runBrowserWithRegistry :: (IOE :> es) => BrowserScope -> BrowserRegistry -> Maybe Text -> Eff (Browser : es) a -> Eff es a
runBrowserWithRegistry scope reg proxy = runBrowser $ \operation -> liftIO $ case operation of
  Navigate url fields -> navigateUrlWith reg scope proxy url fields
  ReadZhihu url -> readZhihuWith reg scope proxy url
  Session method fields
    | method == SessionAction,
      Just action <- KM.lookup "action" (KM.fromList fields),
      Just ("evaluate" :: Text) <- parseMaybe (withObject "action" (.: "type")) action,
      not (browserScopeIsTask scope) ->
        pure (Left "evaluate requires a browser task; use task_start profile=browser")
    | otherwise -> withSession reg scope (methodName method) fields
  where
    methodName SessionSnapshot = "browse_session_snapshot"
    methodName SessionInspect = "browse_session_inspect"
    methodName SessionAction = "browse_session_action"

dropSession :: BrowserRegistry -> BrowserScope -> Text -> Bool -> IO ()
dropSession reg scope sid closeIt = do
  setCamoSession reg scope Nothing
  when closeIt . void $
    callBrowserTool reg scope "browse_session_close" (object ["sessionId" .= sid])

-- | Start a fresh camoufox browse session and record its id.
startSession :: BrowserRegistry -> BrowserScope -> Maybe Text -> IO (Either Text Text)
startSession reg scope proxy = do
  setCamoSession reg scope Nothing
  restored <- takeBrowserRestore reg scope
  let storage = restored >>= parseMaybe (withObject "checkpoint" (.: "storage"))
      startArgs = object (("humanize" .= True) : foldMap (\p -> ["proxy" .= p]) proxy <> foldMap (\saved -> ["storage" .= (saved :: Value)]) storage)
  callBrowserTool reg scope "browse_session_start" startArgs >>= \case
    Left e -> pure (Left (renderBrowserError e))
    Right v -> case sessionIdOf v of
      Nothing ->
        pure (Left ("browse_session_start returned no sessionId: " <> T.take 200 (mcpTextContent v)))
      Just sid -> Right sid <$ setCamoSession reg scope (Just sid)

-- | Pull the @sessionId@ out of a @browse_session_start@ result:
-- prefer the MCP @structuredContent@, fall back to the JSON text block.
sessionIdOf :: Value -> Maybe Text
sessionIdOf v =
  parseMaybe structured v
    <|> (decodeStrict (TE.encodeUtf8 (mcpTextContent v)) >>= parseMaybe fromPayload)
  where
    structured = withObject "result" $ \o -> o .: "structuredContent" >>= fromPayload
    fromPayload :: Value -> Parser Text
    fromPayload = withObject "payload" (.: "sessionId")

-- | Run one @browse_session_*@ tool against the turn's session,
-- injecting @sessionId@.  Requires an existing session; on a
-- session-death error the stored id is dropped and the model is told
-- to re-navigate.
withSession ::
  BrowserRegistry ->
  BrowserScope ->
  Text ->
  [(Key, Value)] ->
  IO (Either Text Value)
withSession reg scope mcpTool fields =
  withBrowserSession reg scope $
    getCamoSession reg scope >>= \case
      Nothing -> pure (Left "no page is open — call browser action=open first")
      Just sid ->
        callBrowserTool reg scope mcpTool (withSid sid fields) >>= \case
          Left err -> case browserErrorKind err of
            BrowserSessionBlocked -> do
              dropSession reg scope sid True
              pure . Left $
                "the browser blocked a request and the session was reset — call browser action=open to reopen ("
                  <> renderBrowserError err
                  <> ")"
            BrowserTransportLost -> pure (Left (renderBrowserError err))
            BrowserSessionGone -> do
              dropSession reg scope sid False
              pure (Left "the browser session expired — call browser action=open to reopen the page")
            BrowserCallFailed -> pure (Left (renderBrowserError err))
          Right value -> pure (Right value)

withSid :: Text -> [(Key, Value)] -> Value
withSid sid fields = object (fields <> ["sessionId" .= sid])

--------------------------------------------------------------------------------
navigateUrl :: BrowserRegistry -> BrowserScope -> Maybe Text -> Text -> IO (Either Text Value)
navigateUrl reg scope proxy url = navigateUrlWith reg scope proxy url ["maxChars" .= zhihuMaxChars, "maxElements" .= (40 :: Int)]

navigateUrlWith :: BrowserRegistry -> BrowserScope -> Maybe Text -> Text -> [(Key, Value)] -> IO (Either Text Value)
navigateUrlWith reg scope proxy url fields =
  withBrowserSession reg scope $
    getCamoSession reg scope >>= \case
      Nothing -> freshNavigate
      Just sid ->
        callBrowserTool reg scope "browse_session_navigate" (navArgs sid) >>= \case
          Left err -> case browserErrorKind err of
            BrowserSessionBlocked -> dropSession reg scope sid True >> freshNavigate
            BrowserSessionGone -> dropSession reg scope sid False >> freshNavigate
            BrowserTransportLost -> pure (Left (renderBrowserError err))
            BrowserCallFailed -> pure (Left (renderBrowserError err))
          Right value -> pure (Right value)
  where
    freshNavigate =
      startSession reg scope proxy
        >>= either
          (pure . Left)
          (\sid -> first renderBrowserError <$> callBrowserTool reg scope "browse_session_navigate" (navArgs sid))
    navArgs sid = withSid sid (fields <> ["url" .= url])

--------------------------------------------------------------------------------
-- view_zhihu

-- | One-call Zhihu reader for share cards.  Plain HTTP gets a 403
-- from Zhihu's edge, and even camoufox eats a challenge page on the
-- first visit of a fresh session — but the challenge sets cookies,
-- and reloading the same URL in the same session goes through
-- (verified: question / answer / zhuanlan pages all render).  So:
-- navigate, and when the response smells like the challenge
-- (non-200, or the slogan-only interstitial), wait and renavigate,
-- up to 'zhihuRetries' times.
readZhihuWith :: BrowserRegistry -> BrowserScope -> Maybe Text -> Text -> IO (Either Text Value)
readZhihuWith reg scope proxy = go zhihuRetries
  where
    go retries url =
      navigateUrl reg scope proxy url >>= \case
        Left e -> pure (Left e)
        Right v -> case navPayload v of
          Just (status, txt)
            | looksLikeChallenge status txt && retries > 0 -> do
                threadDelay 2_500_000
                go (retries - 1) url
            | looksLikeChallenge status txt ->
                pure (Left ("知乎的验证页没绕过去（HTTP " <> T.pack (show status) <> "），稍后再试"))
            | otherwise -> pure (Right (browserView (BrowserBudget zhihuMaxChars 40) "read" v))
          Nothing -> pure (Right (browserView (BrowserBudget zhihuMaxChars 40) "read" v))

    looksLikeChallenge status txt =
      status /= (200 :: Int)
        || ("让每一次点击都充满意义" `T.isInfixOf` txt && T.length txt < 400)

zhihuRetries :: Int
zhihuRetries = 2

zhihuMaxChars :: Int
zhihuMaxChars = 12000

-- | Pull @(status, text)@ out of a @browse_session_navigate@ result:
-- prefer MCP @structuredContent@, fall back to the JSON text block.
navPayload :: Value -> Maybe (Int, Text)
navPayload v =
  parseMaybe structured v
    <|> (decodeStrict (TE.encodeUtf8 (mcpTextContent v)) >>= parseMaybe fromPayload)
  where
    structured = withObject "result" $ \o -> o .: "structuredContent" >>= fromPayload
    fromPayload :: Value -> Parser (Int, Text)
    fromPayload = withObject "payload" $ \o -> (,) <$> o .: "status" <*> o .: "text"
