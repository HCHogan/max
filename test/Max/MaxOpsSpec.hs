module Max.MaxOpsSpec (spec) where

import Control.Concurrent.STM (atomically)
import Control.Monad (forM_)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful (IOE, runEff)
import Max.Config (loadConfigCandidate, runtimeValuesFromConfig)
import Max.Effects.Tools (Tool (..))
import Max.HttpRuntime (HttpRuntime, httpRuntimeFromManagers)
import Max.MaxOps.Client (maxOpsOperations, maxOpsQuery)
import Max.MaxOps.Types
import Max.RuntimeConfig
import Max.Task.Types (TaskProfile (..), taskGrants)
import Max.Tools.MaxOps (maxOpsToolsFor)
import Network.HTTP.Client (ManagerSettings (..), defaultManagerSettings, makeConnection, newManager)
import OneBot.Types (GroupId (..))
import System.Environment (withArgs)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "maxops" $ do
  describe "group authority" $ do
    it "defaults to deny, with no private or standalone foreign chat access" $ do
      maxOpsAllowed defaultMaxOpsConfig (GroupId 611798505) `shouldBe` False
      forM_ [611798506, 0, -611798505, -1000000000001] $ \group ->
        maxOpsAllowed configured (GroupId group) `shouldBe` False
      maxOpsAllowed configured (GroupId 611798505) `shouldBe` True
      maxOpsAllowed (configured {mocAllowedGroups = []}) (GroupId 611798505) `shouldBe` False

    it "does not even register tools for an unlisted group" $ do
      (runtime, requests) <- fixture []
      let tools :: [Tool '[IOE]]
          tools = maxOpsToolsFor runtime configured (pure configured) (GroupId 2)
      map (.toolName) tools `shouldBe` []
      readIORef requests `shouldReturn` []

    it "rechecks current configuration when a previously registered runner executes" $ do
      (runtime, requests) <- fixture []
      current <- newIORef configured
      let tools = maxOpsToolsFor runtime configured (readIORef current) (GroupId 611798505)
      map (.toolName) tools `shouldBe` ["maxops_operations", "maxops_query"]
      writeIORef current (configured {mocAllowedGroups = []})
      forM_ tools $ \tool -> do
        let arguments = if tool.toolName == "maxops_operations" then object [] else queryArgs
        runEff (tool.toolRun arguments) >>= (`shouldSatisfy` isLeft)
      readIORef requests `shouldReturn` []

    it "revokes an old dispatch after atomic config publication" $
      withArgs ["--llm-api-key", "fixture-key"] $ do
        Right base <- loadConfigCandidate
        let values = (runtimeValuesFromConfig base) {rvMaxOps = configured}
            resources = RuntimeResources Nothing [] []
        store <- newRuntimeConfigStore values resources
        lease <- atomically (acquireRuntimeConfigSTM store)
        (runtime, requests) <- fixture []
        let frozen = (leasedRuntimeSnapshot lease).rsValues.rvMaxOps
            current = (.rsValues.rvMaxOps) <$> currentRuntimeSnapshot store
            tools = maxOpsToolsFor runtime frozen current (GroupId 611798505)
        _ <- atomically (publishRuntimeConfigSTM store (values {rvMaxOps = defaultMaxOpsConfig}) resources)
        forM_ tools $ \tool ->
          runEff (tool.toolRun (if tool.toolName == "maxops_operations" then object [] else queryArgs)) >>= (`shouldSatisfy` isLeft)
        readIORef requests `shouldReturn` []
        atomically (releaseRuntimeConfigSTM lease)

    it "background profiles only inherit maxops grants already held by the parent" $ do
      let grants = Map.fromList [("maxops_operations", "catalog-hash"), ("maxops_query", "query-hash")]
      forM_ [Research, Browser, Sandbox] $ \profile -> do
        taskGrants profile grants `shouldBe` grants
        taskGrants profile Map.empty `shouldBe` Map.empty

  describe "authenticated read-only transport" $ do
    it "discovers the hub schema and executes without sending group or principal identity" $
      withToken $ \config -> do
        (runtime, requests) <- fixture [jsonResponse catalog, jsonResponse (object ["state" .= text "unknown"])]
        maxOpsQuery runtime config "fixture.read" (object []) `shouldReturn` Right (object ["state" .= text "unknown"])
        bytes <- BS.concat <$> readIORef requests
        bytes `shouldSatisfy` BS8.isInfixOf "GET /v1/operations"
        bytes `shouldSatisfy` BS8.isInfixOf "POST /v1/execute"
        bytes `shouldSatisfy` BS8.isInfixOf ("Authorization: Bearer " <> fixtureToken)
        bytes `shouldSatisfy` BS8.isInfixOf "{\"op\":\"fixture.read\",\"params\":{}}"
        bytes `shouldSatisfy` (not . BS8.isInfixOf "611798505")

    it "filters mutations from discovery and refuses to execute them" $
      withToken $ \config -> do
        let operations = object ["version" .= (1 :: Int), "operations" .= [operation "fixture.read" True, operation "fixture.write" False]]
        (runtime, requests) <- fixture [jsonResponse operations, jsonResponse operations]
        maxOpsOperations runtime config `shouldReturn` Right catalog
        maxOpsQuery runtime config "fixture.write" (object []) >>= (`shouldSatisfy` isLeft)
        readIORef requests >>= (`shouldSatisfy` (not . BS8.isInfixOf "POST")) . BS.concat

    it "fails closed on unknown protocol versions or missing read-only declarations" $
      withToken $ \config ->
        forM_ [object ["version" .= (2 :: Int), "operations" .= [operation "fixture.read" True]], object ["version" .= (1 :: Int), "operations" .= [object ["name" .= text "fixture.read"]]]] $ \invalid -> do
          (runtime, requests) <- fixture [jsonResponse invalid]
          maxOpsQuery runtime config "fixture.read" (object []) >>= (`shouldSatisfy` isLeft)
          readIORef requests >>= (`shouldSatisfy` (not . BS8.isInfixOf "POST")) . BS.concat

    it "rejects oversize requests and non-object params before reading credentials" $ do
      (runtime, requests) <- fixture []
      maxOpsQuery runtime configured "fixture.read" (object ["large" .= replicate 4096 'x']) >>= (`shouldSatisfy` isLeft)
      maxOpsQuery runtime configured "fixture.read" ("bad" :: Value) >>= (`shouldSatisfy` isLeft)
      readIORef requests `shouldReturn` []

    it "rejects unknown tool fields rather than accepting a forged group or endpoint" $ do
      (runtime, requests) <- fixture []
      let tools = maxOpsToolsFor runtime configured (pure configured) (GroupId 611798505)
      forM_ tools $ \tool ->
        runEff (tool.toolRun (object ["op" .= text "fixture.read", "params" .= object [], "group" .= (611798505 :: Int)])) >>= (`shouldSatisfy` isLeft)
      readIORef requests `shouldReturn` []

    it "does not follow redirects or return error bodies containing credentials" $
      withToken $ \config -> do
        let redirect = "HTTP/1.1 302 Found\r\nLocation: http://untrusted.test/leak\r\nContent-Length: 32\r\n\r\n" <> fixtureToken
        (runtime, requests) <- fixture [redirect]
        maxOpsOperations runtime config `shouldReturn` Left "maxops HTTP 302"
        bytes <- BS.concat <$> readIORef requests
        bytes `shouldSatisfy` (not . BS8.isInfixOf "untrusted.test")

    it "redacts authentication error details" $
      withToken $ \config -> do
        (runtime, _) <- fixture ["HTTP/1.1 401 Unauthorized\r\nContent-Length: 32\r\n\r\n" <> fixtureToken]
        maxOpsOperations runtime config `shouldReturn` Left "maxops HTTP 401"

    it "bounds upstream response bodies" $
      withToken $ \config -> do
        let bytes = BS.replicate (2 * 1024 * 1024 + 1) 120
        (runtime, _) <- fixture [response bytes]
        maxOpsOperations runtime config `shouldReturn` Left "maxops response exceeds 2 MiB"

    it "does not retry a disconnected transport or reveal exception contents" $
      withToken $ \config -> do
        (runtime, requests) <- fixture [BS.empty]
        maxOpsOperations runtime config `shouldReturn` Left "maxops transport unavailable"
        readIORef requests >>= (`shouldSatisfy` BS8.isInfixOf "GET /v1/operations") . BS.concat

    it "requires a bounded printable token and reads rotation from its file" $
      withToken $ \config -> do
        (runtime, requests) <- fixture [jsonResponse catalog, jsonResponse catalog]
        forM_ ["short", BS.replicate 513 120, fixtureToken <> "\nInjected: header"] $ \invalid -> do
          BS.writeFile config.mocTokenFile invalid
          maxOpsOperations runtime config `shouldReturn` Left "maxops credential file is invalid"
        readIORef requests `shouldReturn` []
        BS.writeFile config.mocTokenFile (fixtureToken <> "\r\n")
        maxOpsOperations runtime config `shouldReturn` Right catalog
        BS.writeFile config.mocTokenFile (BS.replicate 32 121)
        maxOpsOperations runtime config `shouldReturn` Right catalog
        readIORef requests >>= (`shouldSatisfy` BS8.isInfixOf ("Authorization: Bearer " <> BS.replicate 32 121)) . BS.concat

configured :: MaxOpsConfig
configured = MaxOpsConfig True "http://hub.test" "/missing/maxops-token" [611798505]

withToken :: (MaxOpsConfig -> IO ()) -> IO ()
withToken action = withSystemTempDirectory "maxops-test" $ \directory -> do
  let path = directory <> "/token"
  BS.writeFile path fixtureToken
  action configured {mocTokenFile = path}

fixtureToken :: BS.ByteString
fixtureToken = BS.replicate 32 120

text :: Text -> Text
text = id

queryArgs :: Value
queryArgs = object ["op" .= text "fixture.read", "params" .= object []]

operation :: Text -> Bool -> Value
operation name readOnly = object ["name" .= name, "read_only" .= readOnly, "params_schema" .= object ["type" .= text "object"]]

catalog :: Value
catalog = object ["version" .= (1 :: Int), "operations" .= [operation "fixture.read" True]]

jsonResponse :: Value -> BS.ByteString
jsonResponse = response . LBS.toStrict . encode

response :: BS.ByteString -> BS.ByteString
response body = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " <> BS8.pack (show (BS.length body)) <> "\r\n\r\n" <> body

fixture :: [BS.ByteString] -> IO (HttpRuntime, IORef [BS.ByteString])
fixture responses = do
  pendingResponses <- newIORef responses
  requests <- newIORef []
  forbidden <- newManager defaultManagerSettings {managerRawConnection = pure $ \_ _ _ -> fail "wrong HTTP pool"}
  manager <-
    newManager
      defaultManagerSettings
        { managerIdleConnectionCount = 0,
          managerRetryableException = const False,
          managerRawConnection = pure $ \_ _ _ -> do
            next <- atomicModifyIORef' pendingResponses $ \case [] -> ([], Nothing); first : rest -> (rest, Just first)
            body <- maybe (fail "unexpected HTTP request or replay") pure next
            chunks <- newIORef [body]
            makeConnection
              (atomicModifyIORef' chunks $ \case [] -> ([], BS.empty); first : rest -> (rest, first))
              (\bytes -> modifyIORef' requests (<> [bytes]))
              (pure ())
        }
  pure (httpRuntimeFromManagers forbidden forbidden manager, requests)
