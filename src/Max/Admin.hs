{-# LANGUAGE TemplateHaskell #-}

-- |
-- The admin JSON API: a warp server inside the bot process, because
-- half of what it manages only exists inside the process.  Sessions
-- are a write-through cache ('Max.Session.updateSession' — a row
-- edited behind the registry's back is a row the bot never sees),
-- running turns live in the task registry, and the LLM usage table is
-- written by this process.  A frontend reads and mutates through
-- here; what shape that frontend takes is deliberately not this
-- module's problem.
--
-- Exposure model: binds @127.0.0.1@ unless told otherwise and does no
-- authentication beyond an optional bearer token — TLS, SSO and the
-- public internet are the reverse proxy's job (cloudflared/Zitadel or
-- an ssh forward).  Absent config section = server never starts.
--
-- Mutations deliberately mirror the command DSL's semantics (grant
-- rows, session overrides, task kills) rather than growing their own:
-- the API caller is the owner tier by definition — whoever can reach
-- this port can also edit max.yaml.
module Max.Admin
  ( AdminConfig (..),
    adminServer,

    -- * Exposed for tests
    Route (..),
    route,
    authOk,
    needsAuth,
  )
where

-- object/(.=) ride in on the Effectful.Log re-export.
import Data.Aeson (Value (..))
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.FileEmbed (embedDir)
import Data.Int (Int64)
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Data.Time (diffUTCTime, getCurrentTime, timeZoneMinutes)
import Data.Version (showVersion)
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Calls (CallDetail (..), CallRow (..), fetchCall, listCalls)
import Max.DB.History (messageStatsDaily)
import Max.DB.Memory (MemoryItem (..), MemoryScope (..), deleteMemory, listMemories, listUserMemoriesEverywhere)
import Max.DB.Permissions (GrantRow (..), deleteGrantById, insertGrant, listGrants)
import Max.DB.Session (listSessions)
import Max.DB.Usage (UsageDay (..), usageDaily)
import Max.Env (BotEnv (..))
import Max.Log (parseLogLevel, renderLogLevel)
import Max.LogBuffer (LogBuffer, LogEntry (..), LogQuery (..), queryLogs)
import Max.LogBuffer qualified as LogBuffer
import Max.Session (Session (..), loadSession, updateSession)
import Max.Tasks (TaskId (..), TaskInfo (..), cancelTask, listTasks)
import Max.Util (trySync)
import Network.HTTP.Types (Method, Status, hAuthorization, hCacheControl, hContentType, methodDelete, methodGet, methodPatch, methodPost, status200, status400, status401, status404, status500)
import Network.Wai (Response, pathInfo, queryString, requestHeaders, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp qualified as Warp
import OneBot.Types (GroupId (..), UserId (..))
import Paths_max (version)

-- | Resolved @admin.*@ config; presence of the section (its @port@)
-- enables the server.
data AdminConfig = AdminConfig
  { -- | Bind address.  The default, @127.0.0.1@, is the deployment
    -- story: anything else is on whoever typed it.
    acHost :: !Text,
    acPort :: !Int,
    -- | Bearer token required on every request when set.  Optional
    -- because a loopback bind behind an authenticating proxy needs
    -- none.
    acToken :: !(Maybe Text)
  }
  deriving stock (Show, Eq)

--------------------------------------------------------------------------------
-- Routing (pure, tested).

-- | One recognised endpoint.  Query parameters and bodies are the
-- handler's business; this is just method + path shape.
data Route
  = ROverview
  | RGroups
  | RSessionPatch !Int64
  | RMemoriesList
  | RMemoryDelete !Int64
  | RGrantsList
  | RGrantCreate
  | RGrantDelete !Int64
  | RTasksList
  | RTaskKill !Text
  | RUsage
  | RMessageStats
  | RLogs
  | RCalls
  | RCallDetail !Int64
  | -- | A baked-in static asset (the panel itself).  Carries the
    -- asset's own path so the handler can look it up; @\/@ is the
    -- index.  Unauthenticated — see 'needsAuth'.
    RStatic ![Text]
  deriving stock (Show, Eq)

-- | Method + path → endpoint.  'Nothing' is a 404.
route :: Method -> [Text] -> Maybe Route
route m path
  | m == methodGet = case path of
      ["api", "overview"] -> Just ROverview
      ["api", "groups"] -> Just RGroups
      ["api", "memories"] -> Just RMemoriesList
      ["api", "permissions"] -> Just RGrantsList
      ["api", "tasks"] -> Just RTasksList
      ["api", "usage"] -> Just RUsage
      ["api", "stats", "messages"] -> Just RMessageStats
      ["api", "logs"] -> Just RLogs
      ["api", "calls"] -> Just RCalls
      ["api", "calls", i] -> RCallDetail <$> int i
      [] -> Just (RStatic ["index.html"])
      [""] -> Just (RStatic ["index.html"])
      ("static" : rest)
        -- No ".." can appear: every asset is baked into the binary and
        -- looked up in a fixed table, so the path is a key, not a
        -- filesystem walk.  Guarded anyway — the day this grows a real
        -- directory the guard is already here.
        | not (null rest), all (`notElem` ["..", ""]) rest ->
            Just (RStatic rest)
      _ -> Nothing
  | m == methodPatch = case path of
      ["api", "groups", g, "session"] -> RSessionPatch <$> int g
      _ -> Nothing
  | m == methodDelete = case path of
      ["api", "memories", i] -> RMemoryDelete <$> int i
      ["api", "permissions", i] -> RGrantDelete <$> int i
      ["api", "tasks", t] | not (T.null t) -> Just (RTaskKill t)
      _ -> Nothing
  | m == methodPost = case path of
      ["api", "permissions"] -> Just RGrantCreate
      _ -> Nothing
  | otherwise = Nothing
  where
    int t = case TR.signed TR.decimal t of
      Right (n, "") -> Just n
      _ -> Nothing

-- | Does the request pass the (optional) bearer check?  No token
-- configured = open — the loopback bind is the guard then.
authOk :: Maybe Text -> Maybe BS.ByteString -> Bool
authOk Nothing _ = True
authOk (Just tok) (Just header) = header == "Bearer " <> TE.encodeUtf8 tok
authOk (Just _) Nothing = False

-- | Which routes the bearer token gates.  The panel's own assets are
-- exempt: a @\<script\>@ tag and a page navigation cannot carry an
-- Authorization header, so gating them would make the token
-- unusable from a browser.  They are HTML/CSS/JS with no data in
-- them — every byte of state still comes from an @\/api@ call that
-- does check.  The panel asks for the token on its first 401 and
-- keeps it in localStorage.
needsAuth :: Route -> Bool
needsAuth = \case
  RStatic _ -> False
  _ -> True

--------------------------------------------------------------------------------
-- Server.

-- | App-lived worker: serve the admin API until the process dies.
adminServer ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  AdminConfig ->
  BotEnv ->
  -- | Configured LLM profile names, for validating a model PATCH.
  [Text] ->
  -- | The process's log tail, served by @\/api\/logs@.
  LogBuffer ->
  Eff es ()
adminServer cfg env profiles logBuf = localDomain "admin" $ do
  logInfo "admin: listening" $ object ["host" .= cfg.acHost, "port" .= cfg.acPort]
  -- Warp serves each request on its own thread, so the unlift has to
  -- be reusable across threads — hence the concurrent strategy.
  withEffToIO (ConcUnlift Ephemeral Unlimited) $ \run ->
    Warp.runSettings settings $ \req respond -> do
      resp <- case route (requestMethod req) (pathInfo req) of
        Nothing -> pure (jsonResponse status404 (object ["error" .= ("not found" :: Text)]))
        Just r
          | needsAuth r,
            not (authOk cfg.acToken (lookup hAuthorization (requestHeaders req))) ->
              pure (jsonResponse status401 (object ["error" .= ("unauthorized" :: Text)]))
        Just (RStatic p) -> pure (staticResponse p)
        Just r -> do
          body <- strictRequestBody req
          run (guarded r (handle env profiles logBuf r (queryPairs req) body))
      respond resp
  where
    settings =
      Warp.setHost (fromString (T.unpack cfg.acHost)) $
        Warp.setPort cfg.acPort Warp.defaultSettings

    -- A handler that throws must answer 500, not kill the connection
    -- silently — and must never take the worker down.
    guarded r act =
      trySync act >>= \case
        Right resp -> pure resp
        Left e -> do
          logAttention "admin: handler crashed" $
            object ["route" .= T.pack (show r), "error" .= T.pack (show e)]
          pure (jsonResponse status500 (object ["error" .= ("internal error" :: Text)]))

    queryPairs req =
      [ (TE.decodeUtf8Lenient k, TE.decodeUtf8Lenient v)
      | (k, Just v) <- queryString req
      ]

jsonResponse :: A.ToJSON a => Status -> a -> Response
jsonResponse st v =
  responseLBS st [(hContentType, "application/json; charset=utf-8")] (A.encode v)

--------------------------------------------------------------------------------
-- The panel itself.

-- | Every file under @static\/@, baked into the binary at compile
-- time.  Embedding rather than reading from disk keeps the deployment
-- story ("one binary, systemd starts it") intact — a panel that
-- needed its assets installed next to it would be a second thing to
-- get right in the nix derivation.  The tree is ~100 KB of vendored
-- JS/CSS, which is noise next to the RTS.
staticAssets :: [(FilePath, BS.ByteString)]
staticAssets = $(embedDir "static")

-- | Serve one embedded asset.  Assets are content-addressed by build
-- (they change only when the binary does), so vendored libraries get
-- a long cache lifetime while the panel's own files stay
-- revalidated — otherwise a bot upgrade would serve yesterday's
-- app.js out of the browser cache.
staticResponse :: [Text] -> Response
staticResponse segs = case lookup key staticAssets of
  Nothing -> jsonResponse status404 (object ["error" .= ("not found" :: Text)])
  Just bytes ->
    responseLBS
      status200
      [ (hContentType, contentType),
        ( hCacheControl,
          if "vendor/" `T.isPrefixOf` T.pack key
            then "public, max-age=31536000, immutable"
            else "no-cache"
        )
      ]
      (LBS.fromStrict bytes)
  where
    key = T.unpack (T.intercalate "/" segs)
    ext s = s `T.isSuffixOf` T.pack key
    contentType
      | ext ".html" = "text/html; charset=utf-8"
      | ext ".js" = "text/javascript; charset=utf-8"
      | ext ".css" = "text/css; charset=utf-8"
      -- Fonts load from @font-face either way, but a wrong type is
      -- the kind of thing that only bites once something in front
      -- (a CSP, a caching proxy) starts caring.
      | ext ".woff2" = "font/woff2"
      | ext ".svg" = "image/svg+xml"
      | otherwise = "application/octet-stream"

--------------------------------------------------------------------------------
-- Handlers.

handle ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  BotEnv ->
  [Text] ->
  LogBuffer ->
  Route ->
  [(Text, Text)] ->
  LBS.ByteString ->
  Eff es Response
handle env profiles logBuf r params body = case r of
  ROverview -> do
    now <- liftIO getCurrentTime
    tasks <- liftIO (listTasks env.beTasks Nothing)
    sessions <- listSessions env.beDefaultModel
    pure . ok $
      object
        [ "version" .= showVersion version,
          "uptime_seconds" .= (round (diffUTCTime now env.beStartedAt) :: Int64),
          "default_model" .= env.beDefaultModel,
          "profiles" .= profiles,
          "owners" .= env.beOwners,
          "groups" .= length sessions,
          "running_tasks" .= length tasks
        ]
  RGroups -> do
    sessions <- listSessions env.beDefaultModel
    pure (ok (map sessionJson sessions))
  RSessionPatch gidRaw ->
    case A.eitherDecode body of
      Left err -> pure (bad ("invalid json: " <> T.pack err))
      Right (Object o) -> applySessionPatch env profiles gidRaw o
      Right _ -> pure (bad "body must be a json object")
  RMemoriesList -> case (lookup "scope" params, intParam "id") of
    (Just "group", Just gid) -> do
      mems <- listMemories ScopeGroup gid gid
      pure (ok (map (memoryJson Nothing) mems))
    (Just "user", Just uid) -> do
      mems <- listUserMemoriesEverywhere uid
      pure (ok (map (\(m, src) -> memoryJson src m) mems))
    _ -> pure (bad "expected ?scope=group|user&id=<qq/群号>")
  RMemoryDelete mid -> do
    gone <- deleteMemory mid
    pure (if gone then deleted else notFound)
  RGrantsList -> ok . map grantJson <$> listGrants
  RGrantCreate ->
    case A.eitherDecode body :: Either String PostGrant of
      Left err -> pure (bad ("invalid json: " <> T.pack err))
      Right g -> do
        -- granted_by 0 marks rows minted here rather than by a QQ
        -- user; the audit column keeps meaning either way.
        insertGrant g.pgUser g.pgCapability g.pgScope g.pgDeny 0
        ok . map grantJson <$> listGrants
  RGrantDelete rid -> do
    gone <- deleteGrantById rid
    pure (if gone then deleted else notFound)
  RTasksList -> do
    tasks <- liftIO (listTasks env.beTasks Nothing)
    pure (ok (map taskJson tasks))
  RTaskKill tid -> do
    killed <- liftIO (cancelTask env.beTasks (TaskId tid))
    pure (if killed then deleted else notFound)
  RUsage -> do
    let days = clampDays (fromMaybe 30 (intParam "days"))
    rows <- usageDaily (timeZoneMinutes env.beTimeZone) days
    pure . ok $
      [ object
          [ "day" .= u.udDay,
            "group_id" .= u.udGroup,
            "source" .= u.udSource,
            "profile" .= u.udProfile,
            "calls" .= u.udCalls,
            "prompt_tokens" .= u.udPrompt,
            "completion_tokens" .= u.udCompletion,
            "cached_prompt_tokens" .= u.udCachedPrompt
          ]
      | u <- rows
      ]
  RMessageStats -> do
    let days = clampDays (fromMaybe 14 (intParam "days"))
    rows <- messageStatsDaily (timeZoneMinutes env.beTimeZone) days
    pure . ok $
      [ object ["day" .= d, "group_id" .= g, "kind" .= k, "count" .= n]
      | (d, g, k, n) <- rows
      ]
  -- The panel polls this with ?after=<seq> to tail, so the response
  -- carries the highest sequence number it contains — the client
  -- echoes it back and never re-reads a line it already has.
  RLogs -> do
    entries <-
      liftIO . queryLogs logBuf $
        LogBuffer.emptyQuery
          { lqMinLevel = parseLogLevel =<< lookup "level" params,
            lqDomain = nonBlank =<< lookup "domain" params,
            lqSearch = nonBlank =<< lookup "q" params,
            lqAfter = intParam "after",
            lqLimit = max 1 (min 1000 (fromMaybe 200 (intParam "limit")))
          }
    pure . ok $
      object
        [ "entries"
            .= [ object
                   [ "seq" .= e.leSeq,
                     "at" .= e.leAt,
                     "level" .= renderLogLevel e.leLevel,
                     "domain" .= e.leDomain,
                     "message" .= e.leMessage,
                     "data" .= e.leData
                   ]
               | e <- entries
               ],
          -- Newest first, so the head is the high-water mark.
          "latest" .= case entries of
            (e : _) -> Just e.leSeq
            [] -> Nothing
        ]
  -- The list omits the bodies — they are tens of kilobytes apiece and
  -- the list is the index, not the reading.  Sizes ride along so you
  -- can see which call is the big one before opening it.
  RCalls -> do
    rows <-
      listCalls
        (intParam "group")
        (nonBlank =<< lookup "source" params)
        (lookup "failed" params == Just "1")
        (intParam "before")
        (max 1 (min 200 (fromMaybe 50 (intParam "limit"))))
    pure (ok (map callRowJson rows))
  RCallDetail cid ->
    fetchCall cid >>= \case
      Nothing -> pure notFound
      Just d ->
        pure . ok $
          case callRowJson d.cdRow of
            Object o ->
              Object (o <> KM.fromList ["request" .= d.cdRequest, "response" .= d.cdResponse])
            v -> v
  -- Answered by 'staticResponse' before the effectful handler is
  -- entered (it needs no database and no unlift); listed so the match
  -- stays total if that ever changes.
  RStatic p -> pure (staticResponse p)
  where
    nonBlank t = if T.null (T.strip t) then Nothing else Just (T.strip t)
    ok :: A.ToJSON a => a -> Response
    ok = jsonResponse status200
    bad msg = jsonResponse status400 (object ["error" .= (msg :: Text)])
    notFound = jsonResponse status404 (object ["error" .= ("not found" :: Text)])
    deleted = jsonResponse status200 (object ["deleted" .= True])
    intParam :: Integral a => Text -> Maybe a
    intParam k = do
      v <- lookup k params
      case TR.signed TR.decimal v of
        Right (n, "") -> Just n
        _ -> Nothing
    -- A runaway ?days= must not turn into a full-table scan festival.
    clampDays n = max 1 (min 365 n)

-- | Apply a session PATCH through the registry, never the DB alone —
-- the running process trusts its in-memory copy.  Field semantics:
-- absent = untouched, @null@ = clear the override, value = set it.
applySessionPatch ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  BotEnv ->
  [Text] ->
  Int64 ->
  A.Object ->
  Eff es Response
applySessionPatch env profiles gidRaw o =
  case badModel of
    Just m ->
      pure (jsonResponse status400 (object ["error" .= ("unknown model: " <> m), "profiles" .= profiles]))
    Nothing -> case edits of
      Left err -> pure (jsonResponse status400 (object ["error" .= err]))
      Right [] -> pure (jsonResponse status400 (object ["error" .= ("no recognised fields" :: Text)]))
      Right es -> do
        t <- loadSession env.beSessions env.beDefaultModel (GroupId gidRaw)
        patched <- updateSession t (\s -> let s2 = foldl (flip ($)) s es in (s2, s2))
        logInfo "admin: session patched" $
          object ["group_id" .= gidRaw, "fields" .= map fst recognised]
        pure (jsonResponse status200 (sessionJson patched))
  where
    recognised =
      [ (k, v)
      | (key, v) <- KM.toList o,
        let k = Key.toText key,
        k `elem` (["model", "persona", "debug", "sticker", "proactive"] :: [Text])
      ]
    badModel = case KM.lookup "model" o of
      Just (String m) | m `notElem` profiles -> Just m
      _ -> Nothing
    edits :: Either Text [Session -> Session]
    edits = traverse toEdit recognised
    toEdit = \case
      ("model", String m) -> Right (\s -> s {model = m})
      ("persona", String p) -> Right (\s -> s {persona = Just p})
      ("persona", Null) -> Right (\s -> s {persona = Nothing})
      ("debug", Bool b) -> Right (\s -> s {debugOverride = Just b})
      ("debug", Null) -> Right (\s -> s {debugOverride = Nothing})
      ("sticker", Bool b) -> Right (\s -> s {stickerOverride = Just b})
      ("sticker", Null) -> Right (\s -> s {stickerOverride = Nothing})
      ("proactive", Bool b) -> Right (\s -> s {proactiveOverride = Just b})
      ("proactive", Null) -> Right (\s -> s {proactiveOverride = Nothing})
      (k, _) -> Left ("bad value for field: " <> k)

--------------------------------------------------------------------------------
-- JSON shapes.

sessionJson :: Session -> Value
sessionJson s =
  object
    [ "group_id" .= (let GroupId g = s.groupId in g),
      "model" .= s.model,
      "persona" .= s.persona,
      "cleared_at" .= s.clearedAt,
      "pinned" .= s.pinned,
      "debug" .= s.debugOverride,
      "sticker" .= s.stickerOverride,
      "proactive" .= s.proactiveOverride,
      "context_anchor" .= s.contextAnchor
    ]

memoryJson :: Maybe Int64 -> MemoryItem -> Value
memoryJson sourceGroup m =
  object
    [ "id" .= m.memId,
      "scope" .= m.memScope,
      "scope_id" .= m.memScopeId,
      "content" .= m.memContent,
      "updated_at" .= m.memUpdatedAt,
      "source_group_id" .= sourceGroup
    ]

grantJson :: GrantRow -> Value
grantJson g =
  object
    [ "id" .= g.grId,
      "user_id" .= g.grUser,
      "capability" .= g.grCapability,
      "scope_group_id" .= g.grScope,
      "deny" .= g.grDeny,
      "granted_by" .= g.grGrantedBy,
      "granted_at" .= g.grGrantedAt
    ]

callRowJson :: CallRow -> Value
callRowJson c =
  object
    [ "id" .= c.crId,
      "at" .= c.crAt,
      "group_id" .= c.crGroup,
      "source" .= c.crSource,
      "profile" .= c.crProfile,
      "model" .= c.crModel,
      "streamed" .= c.crStreamed,
      "duration_ms" .= c.crDurationMs,
      "error" .= c.crError,
      "prompt_tokens" .= c.crPrompt,
      "completion_tokens" .= c.crCompletion,
      "cached_prompt_tokens" .= c.crCached,
      "request_bytes" .= c.crReqBytes,
      "response_bytes" .= c.crRespBytes
    ]

taskJson :: TaskInfo -> Value
taskJson ti =
  object
    [ "id" .= ti.tiId.unTaskId,
      "group_id" .= (let GroupId g = ti.tiGroup in g),
      "user_id" .= (let UserId u = ti.tiUser in u),
      "trigger_message_id" .= ti.tiTrigger,
      "kind" .= ti.tiKind,
      "started_at" .= ti.tiStartedAt,
      "pending_notes" .= ti.tiPending
    ]

-- | Body of @POST /api/permissions@.
data PostGrant = PostGrant
  { pgUser :: !Int64,
    pgCapability :: !Text,
    pgScope :: !(Maybe Int64),
    pgDeny :: !Bool
  }

instance A.FromJSON PostGrant where
  parseJSON = A.withObject "grant" $ \o ->
    PostGrant
      <$> o A..: "user_id"
      <*> o A..: "capability"
      <*> o A..:? "scope_group_id"
      <*> (fromMaybe False <$> o A..:? "deny")
