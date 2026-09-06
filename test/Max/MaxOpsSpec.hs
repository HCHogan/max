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
import Max.MaxOps.Client (maxOpsOperations, maxOpsQuery, maxOpsExecute)
import Max.MaxOps.Protocol (CatalogAccess (..), parseCatalog, withLogText)
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
          tools = maxOpsToolsFor runtime configured (pure configured) (GroupId 2) ManagementCatalog
      map (.toolName) tools `shouldBe` []
      readIORef requests `shouldReturn` []

    it "rechecks current configuration when a previously registered runner executes" $ do
      (runtime, requests) <- fixture []
      current <- newIORef configured
      let tools = maxOpsToolsFor runtime configured (readIORef current) (GroupId 611798505) ManagementCatalog
      map (.toolName) tools `shouldBe` ["maxops_operations", "maxops_query", "maxops_execute"]
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
            tools = maxOpsToolsFor runtime frozen current (GroupId 611798505) ManagementCatalog
        _ <- atomically (publishRuntimeConfigSTM store (values {rvMaxOps = defaultMaxOpsConfig}) resources)
        forM_ tools $ \tool ->
          runEff (tool.toolRun (if tool.toolName == "maxops_operations" then object [] else queryArgs)) >>= (`shouldSatisfy` isLeft)
        readIORef requests `shouldReturn` []
        atomically (releaseRuntimeConfigSTM lease)

    it "background profiles only inherit maxops grants already held by the parent" $ do
      let grants = Map.fromList [("maxops_operations", "catalog-hash"), ("maxops_query", "query-hash")]
      forM_ [Research, Browser, Sandbox, Operations] $ \profile -> do
        taskGrants profile grants `shouldBe` grants
        taskGrants profile Map.empty `shouldBe` Map.empty

    it "only lets the operations profile inherit an existing management grant" $ do
      let grant = Map.singleton "maxops_execute" "management-hash"
      taskGrants Operations grant `shouldBe` grant
      forM_ [Research, Browser, Sandbox] $ \profile -> taskGrants profile grant `shouldBe` Map.empty

    it "hides management runners and operations from a read-only task even with a management credential" $
      withToken $ \config -> do
        (runtime, _) <- fixture [jsonResponse catalogV2]
        let tools = maxOpsToolsFor runtime config (pure config) (GroupId 611798505) ReadOnlyCatalog
        map (.toolName) tools `shouldBe` ["maxops_operations", "maxops_query"]
        case tools of
          catalogTool : _ -> runEff (catalogTool.toolRun (object [])) `shouldReturn`
            Right (object ["version" .= (2 :: Int), "operations" .= [operationV2 "fixture.status" "job_control" True "none"]])
          _ -> expectationFailure "missing read-only catalog"

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
        maxOpsOperations runtime config ManagementCatalog `shouldReturn` Right catalog
        maxOpsQuery runtime config "fixture.write" (object []) >>= (`shouldSatisfy` isLeft)
        readIORef requests >>= (`shouldSatisfy` (not . BS8.isInfixOf "POST")) . BS.concat

    it "fails closed on unknown protocol versions or missing read-only declarations" $
      withToken $ \config ->
        forM_ [object ["version" .= (3 :: Int), "operations" .= [operation "fixture.read" True]], object ["version" .= (1 :: Int), "operations" .= [object ["name" .= text "fixture.read"]]]] $ \invalid -> do
          (runtime, requests) <- fixture [jsonResponse invalid]
          maxOpsQuery runtime config "fixture.read" (object []) >>= (`shouldSatisfy` isLeft)
          readIORef requests >>= (`shouldSatisfy` (not . BS8.isInfixOf "POST")) . BS.concat

    it "rejects oversize requests and non-object params before reading credentials" $ do
      (runtime, requests) <- fixture []
      maxOpsQuery runtime configured "fixture.read" (object ["large" .= replicate (2 * 1024 * 1024) 'x']) >>= (`shouldSatisfy` isLeft)
      maxOpsQuery runtime configured "fixture.read" ("bad" :: Value) >>= (`shouldSatisfy` isLeft)
      readIORef requests `shouldReturn` []

    it "rejects unknown tool fields rather than accepting a forged group or endpoint" $ do
      (runtime, requests) <- fixture []
      let tools = maxOpsToolsFor runtime configured (pure configured) (GroupId 611798505) ManagementCatalog
      forM_ tools $ \tool ->
        runEff (tool.toolRun (object ["op" .= text "fixture.read", "params" .= object [], "group" .= (611798505 :: Int)])) >>= (`shouldSatisfy` isLeft)
      readIORef requests `shouldReturn` []

  describe "protocol 2 management transport" $ do
    it "makes binary log chunks readable without losing byte offsets or truncation state" $ do
      let logs = object ["encoding" .= text "base64", "stdout_base64" .= text "aGkK", "stderr_base64" .= text "/w==", "next_stdout_offset" .= (3 :: Int), "truncated" .= True]
          expected = object ["encoding" .= text "base64", "stdout_base64" .= text "aGkK", "stderr_base64" .= text "/w==", "next_stdout_offset" .= (3 :: Int), "truncated" .= True, "stdout_text" .= text "hi\n", "stderr_text" .= text "\xfffd", "text_decoding" .= text "utf8_with_replacement"]
      withLogText logs `shouldBe` Right expected
      withLogText (object ["encoding" .= text "base64", "stdout_base64" .= text "bad", "stderr_base64" .= text ""]) `shouldSatisfy` isLeft

    it "preserves effect and response metadata, including durable job readers and writes" $
      withToken $ \config -> do
        (runtime, _) <- fixture [jsonResponse catalogV2, jsonResponse catalogV2, jsonResponse (object ["handle" .= text "existing-job"])]
        maxOpsOperations runtime config ManagementCatalog `shouldReturn` Right catalogV2
        maxOpsQuery runtime config "fixture.status" (object []) `shouldReturn` Right (object ["handle" .= text "existing-job"])

    it "keeps reads and mutations on separate execution paths" $
      withToken $ \config -> do
        (runtime, requests) <- fixture (replicate 3 (jsonResponse catalogV2))
        maxOpsQuery runtime config "fixture.submit" (object []) >>= (`shouldSatisfy` isLeft)
        maxOpsExecute runtime config "fixture.status" (object []) Nothing >>= (`shouldSatisfy` isLeft)
        maxOpsExecute runtime config "fixture.missing" (object []) Nothing >>= (`shouldSatisfy` isLeft)
        readIORef requests >>= (`shouldSatisfy` (not . BS8.isInfixOf "POST")) . BS.concat

    it "forwards stable submission keys as headers and returns the exact durable handle" $
      withToken $ \config -> do
        let handle = object ["job_id" .= text "job-123", "state" .= text "queued", "revision" .= (1 :: Int)]
        (runtime, requests) <- fixture [jsonResponse catalogV2, jsonResponse handle, jsonResponse catalogV2, jsonResponse handle]
        forM_ [1, 2 :: Int] $ \_ -> maxOpsExecute runtime config "fixture.submit" (object []) (Just "incident-123") `shouldReturn` Right handle
        sent <- readIORef requests
        length [() | request <- sent, "Idempotency-Key: incident-123" `BS8.isInfixOf` request] `shouldBe` 2
        BS.concat sent `shouldSatisfy` (not . BS8.isInfixOf "\"idempotency_key\"")

    it "rejects missing, unexpected or unsafe keys before submitting anything" $
      withToken $ \config -> do
        (runtime, requests) <- fixture [jsonResponse catalogV2, jsonResponse catalogV2]
        maxOpsExecute runtime config "fixture.submit" (object []) Nothing >>= (`shouldSatisfy` isLeft)
        maxOpsExecute runtime config "fixture.control" (object []) (Just "not-supported") >>= (`shouldSatisfy` isLeft)
        forM_ ["", "has space", "x\r\nInjected: value", "中文", "nul\0", "long" <> text (mconcat (replicate 128 "x"))] $ \key ->
          maxOpsExecute runtime config "fixture.submit" (object []) (Just key) >>= (`shouldSatisfy` isLeft)
        readIORef requests >>= (`shouldSatisfy` (not . BS8.isInfixOf "POST")) . BS.concat

    it "accepts revisioned controls and workspace-sized payloads without inventing an idempotency contract" $
      withToken $ \config -> do
        let params = object ["expected_revision" .= (4 :: Int), "contents" .= replicate 8192 'x']
        (runtime, requests) <- fixture [jsonResponse catalogV2, jsonResponse (object ["revision" .= (5 :: Int)])]
        maxOpsExecute runtime config "fixture.control" params Nothing `shouldReturn` Right (object ["revision" .= (5 :: Int)])
        readIORef requests >>= (`shouldSatisfy` (not . BS8.isInfixOf "Idempotency-Key")) . BS.concat

    it "never automatically replays a write when its HTTP acknowledgement is lost" $
      withToken $ \config -> do
        (runtime, requests) <- fixture [jsonResponse catalogV2, BS.empty]
        maxOpsExecute runtime config "fixture.submit" (object []) (Just "stable-key") `shouldReturn` Left "maxops transport unavailable"
        sent <- readIORef requests
        length [() | request <- sent, "POST /v1/execute" `BS8.isInfixOf` request] `shouldBe` 1

    it "rejects duplicate operation names and inconsistent protocol-2 effect contracts" $ do
      let invalid entries = object ["version" .= (2 :: Int), "operations" .= entries]
      forM_ [ [operationV2 "duplicate" "observation" True "none", operationV2 "duplicate" "job_submission" False "required"],
              [operationV2 "unsafe" "job_submission" True "required"],
              [operationV2 "unsafe" "observation" False "none"],
              [operationV2 "unsafe" "job_control" False "required"],
              [operation "missing-v2-metadata" True]
            ] $ \entries -> parseCatalog (invalid entries) `shouldSatisfy` isLeft

    it "does not follow redirects or return error bodies containing credentials" $
      withToken $ \config -> do
        let redirect = "HTTP/1.1 302 Found\r\nLocation: http://untrusted.test/leak\r\nContent-Length: 32\r\n\r\n" <> fixtureToken
        (runtime, requests) <- fixture [redirect]
        maxOpsOperations runtime config ManagementCatalog `shouldReturn` Left "maxops HTTP 302"
        bytes <- BS.concat <$> readIORef requests
        bytes `shouldSatisfy` (not . BS8.isInfixOf "untrusted.test")

    it "redacts authentication error details" $
      withToken $ \config -> do
        (runtime, _) <- fixture ["HTTP/1.1 401 Unauthorized\r\nContent-Length: 32\r\n\r\n" <> fixtureToken]
        maxOpsOperations runtime config ManagementCatalog `shouldReturn` Left "maxops HTTP 401"

    it "bounds upstream response bodies" $
      withToken $ \config -> do
        let bytes = BS.replicate (2 * 1024 * 1024 + 1) 120
        (runtime, _) <- fixture [response bytes]
        maxOpsOperations runtime config ManagementCatalog `shouldReturn` Left "maxops response exceeds 2 MiB"

    it "does not retry a disconnected transport or reveal exception contents" $
      withToken $ \config -> do
        (runtime, requests) <- fixture [BS.empty]
        maxOpsOperations runtime config ManagementCatalog `shouldReturn` Left "maxops transport unavailable"
        readIORef requests >>= (`shouldSatisfy` BS8.isInfixOf "GET /v1/operations") . BS.concat

    it "requires a bounded printable token and reads rotation from its file" $
      withToken $ \config -> do
        (runtime, requests) <- fixture [jsonResponse catalog, jsonResponse catalog]
        forM_ ["short", BS.replicate 513 120, fixtureToken <> "\nInjected: header"] $ \invalid -> do
          BS.writeFile config.mocTokenFile invalid
          maxOpsOperations runtime config ManagementCatalog `shouldReturn` Left "maxops credential file is invalid"
        readIORef requests `shouldReturn` []
        BS.writeFile config.mocTokenFile (fixtureToken <> "\r\n")
        maxOpsOperations runtime config ManagementCatalog `shouldReturn` Right catalog
        BS.writeFile config.mocTokenFile (BS.replicate 32 121)
        maxOpsOperations runtime config ManagementCatalog `shouldReturn` Right catalog
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

operationV2 :: Text -> Text -> Bool -> Text -> Value
operationV2 name kind readOnly idempotency = object
  ["name" .= name, "kind" .= kind, "read_only" .= readOnly, "idempotency" .= idempotency,
   "minimum_protocol_version" .= (2 :: Int), "params_schema" .= object ["type" .= text "object"],
   "response_schema" .= object ["type" .= text "object"]]

catalogV2 :: Value
catalogV2 = object ["version" .= (2 :: Int), "operations" .=
  [operationV2 "fixture.status" "job_control" True "none",
   operationV2 "fixture.submit" "job_submission" False "required",
   operationV2 "fixture.control" "job_control" False "none"]]

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
