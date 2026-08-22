{-# LANGUAGE TemplateHaskell #-}

-- |
-- The admin JSON API: a warp server inside the bot process, because
-- half of what it manages only exists inside the process.  Sessions
-- are a revisioned write-through cache ('Max.Session.updateSession' persists
-- CAS before publishing the TVar; a row edited behind the registry's back is
-- refreshed on the next conflicting mutation),
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
-- Mutations deliberately mirror the command DSL's semantics (the
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
import Data.Aeson.Types (Pair)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.FileEmbed (embedDir)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Ord (clamp)
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Data.Time (diffUTCTime, getCurrentTime, timeZoneMinutes)
import Data.Version (showVersion)
import Effectful
import Effectful.Concurrent (Concurrent)
import Effectful.Log
import Effectful.PostgreSQL (WithConnection, query)
import Max.AdminTimeline (loadAdminTimeline, waitAdminTimeline)
import Max.BuildInfo (gitRev)
import Max.CliProxy (CliProxyConfig (..), credentialJson, fetchCredentials)
import Max.Command.Parser (effortLevels)
import Max.ContextAdmin
  ( enqueueContextRebuildAdmin,
    fetchMemoryHistoryAdmin,
    invalidateEmbeddingsAdmin,
    listCaptureRunsAdmin,
    listCompartmentsAdmin,
    listPlanTracesAdmin,
    loadContextStatus,
    loadEmbeddingStatus,
    runContextIntegrityCheck,
  )
import Max.ConversationScope (conversationScopeFor, currentConversationRecall)
import Max.DB.Calls (CallDetail (..), CallRow (..), fetchCall, listCalls)
import Max.DB.History (MessageCursor (..), messageStatsDaily)
import Max.DB.Session (listSessions)
import Max.DB.Usage (UsageDay (..), usageDaily)
import Max.Effects.Blob (Blob, blobRefFromSha256, readBlob)
import Max.Effects.Embedding (Embedding, EmbeddingSpace (..), embedBatch, embeddingSpace, renderEmbeddingFault)
import Max.Effects.Http (Http)
import Max.Effects.Tools (ToolRef (..))
import Max.Embedding (EmbeddingRecord)
import Max.Env (BotEnv (..))
import Max.EpisodeStore (CaptureRun (..), CompartmentId (..), SourceRange (..), episodeHandleText)
import Max.Log (parseLogLevel, renderLogLevel)
import Max.LogBuffer (LogBuffer, LogEntry (..), LogQuery (..), queryLogs)
import Max.LogBuffer qualified as LogBuffer
import Max.MemoryStore
  ( ExpectedVersion (..),
    MemoryActor (..),
    MemoryActorKind (..),
    MemoryId (..),
    MemoryItem (..),
    MemoryMutationResult (..),
    archiveMemoryAdmin,
    fetchMemoryAdmin,
    groupMemoryNamespace,
    listMemories,
    listUserMemoriesEverywhereAdmin,
  )
import Max.Plan.Catalog (planCatalog)
import Max.Plan.Parse (parseFailureText, parsePlan)
import Max.Plan.Types (planChildren, planHash, planHoles)
import Max.Plan.Validate (rejectionText, validatePlan)
import Max.Platform.Store (ConversationSummary (..), listConversations, listPlatformStatus)
import Max.Platform.Types (noAdvertisedCaps)
import Max.Recall
  ( RecallCandidate (..),
    RecallHit (..),
    RecallTrace (..),
    RecallTraceCandidate (..),
    searchRecallTrace,
  )
import Max.Session (Session (..), loadSession, updateSession)
import Max.Skills (NewSkill (..), Skill (..), createSkill, deleteSkill, listAllSkills, updateSkill)
import Max.Tasks (TaskId (..), TaskInfo (..), cancelTask, listTasks)
import Max.ToolContext (TurnCapabilities (..))
import Max.Tools.Plan (validationEnvForContract)
import Max.Toolset (toolDefinitionsFor)
import Max.Util (trySync)
import Network.HTTP.Types (Method, Status, hAuthorization, hCacheControl, hContentType, methodDelete, methodGet, methodPatch, methodPost, status200, status400, status401, status404, status409, status500, status502)
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
  | -- | Every conversation the ledger knows, for the panel's picker.
    RConversations
  | RGroups
  | RSessionPatch !Int64
  | RMemoriesList
  | RMemoryDelete !Int64
  | RSkillsList
  | RSkillCreate
  | RSkillPatch !Int64
  | RSkillDelete !Int64
  | RTasksList
  | RTaskKill !Text
  | RUsage
  | -- | Health of the credential pool serving our LLM base URL.
    RQuota
  | RMessageStats
  | RLogs
  | RCalls
  | RCallDetail !Int64
  | RPlatformStatus
  | RPlatformTimeline !Int64
  | RPlatformTimelineWait !Int64
  | RBlob !Text
  | RContextStatus
  | RContextCaptures
  | RContextCompartments
  | RContextPlans
  | RContextMemory !Int64
  | RContextEmbeddings
  | RContextRecall
  | RContextIntegrity
  | RPlanCheck
  | RContextRebuild
  | RContextReindex
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
      ["api", "conversations"] -> Just RConversations
      ["api", "groups"] -> Just RGroups
      ["api", "memories"] -> Just RMemoriesList
      ["api", "skills"] -> Just RSkillsList
      ["api", "tasks"] -> Just RTasksList
      ["api", "usage"] -> Just RUsage
      ["api", "quota"] -> Just RQuota
      ["api", "stats", "messages"] -> Just RMessageStats
      ["api", "logs"] -> Just RLogs
      ["api", "calls"] -> Just RCalls
      ["api", "calls", i] -> RCallDetail <$> int i
      ["api", "platforms", "status"] -> Just RPlatformStatus
      ["api", "platforms", "timeline", g] -> RPlatformTimeline <$> int g
      ["api", "platforms", "timeline", g, "wait"] -> RPlatformTimelineWait <$> int g
      ["api", "blobs", sha] | not (T.null sha) -> Just (RBlob sha)
      ["api", "context", "status"] -> Just RContextStatus
      ["api", "context", "captures"] -> Just RContextCaptures
      ["api", "context", "compartments"] -> Just RContextCompartments
      ["api", "context", "plans"] -> Just RContextPlans
      ["api", "context", "memories", i] -> RContextMemory <$> int i
      ["api", "context", "embeddings"] -> Just RContextEmbeddings
      ["api", "context", "recall"] -> Just RContextRecall
      ["api", "context", "integrity"] -> Just RContextIntegrity
      [] -> Just (RStatic ["index.html"])
      [""] -> Just (RStatic ["index.html"])
      ("static" : rest)
        -- No ".." can appear: every asset is baked into the binary and
        -- looked up in a fixed table, so the path is a key, not a
        -- filesystem walk.  Guarded anyway — the day this grows a real
        -- directory the guard is already here.
        | not (null rest),
          all (`notElem` ["..", ""]) rest ->
            Just (RStatic rest)
      _ -> Nothing
  | m == methodPatch = case path of
      ["api", "groups", g, "session"] -> RSessionPatch <$> int g
      ["api", "skills", i] -> RSkillPatch <$> int i
      _ -> Nothing
  | m == methodDelete = case path of
      ["api", "memories", i] -> RMemoryDelete <$> int i
      ["api", "skills", i] -> RSkillDelete <$> int i
      ["api", "tasks", t] | not (T.null t) -> Just (RTaskKill t)
      _ -> Nothing
  | m == methodPost = case path of
      ["api", "skills"] -> Just RSkillCreate
      ["api", "plan", "check"] -> Just RPlanCheck
      ["api", "context", "rebuild"] -> Just RContextRebuild
      ["api", "context", "reindex"] -> Just RContextReindex
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
  (Embedding :> es, Http :> es, Blob :> es, Concurrent :> es, WithConnection :> es, Log :> es, IOE :> es) =>
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

jsonResponse :: (A.ToJSON a) => Status -> a -> Response
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
  (Embedding :> es, Http :> es, Blob :> es, Concurrent :> es, WithConnection :> es, Log :> es, IOE :> es) =>
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
    accounts <- botAccounts
    health <- healthCounters
    warned <- liftIO (LogBuffer.countAtLeast logBuf LogAttention)
    pure . ok $
      object
        [ "version" .= showVersion version,
          "git_rev" .= fmap T.pack gitRev,
          "uptime_seconds" .= (round (diffUTCTime now env.beStartedAt) :: Int64),
          "default_model" .= env.beDefaultModel,
          "profiles" .= profiles,
          "effort_levels" .= effortLevels,
          "owners" .= env.beOwners,
          "groups" .= length sessions,
          "running_tasks" .= length tasks,
          -- Who the bot is on each platform it is logged into: the
          -- panel's footer says whose console this is, and until now
          -- the API could not answer that.
          "accounts" .= accounts,
          -- One glance's worth of "is anything wrong", cheap enough to
          -- ride along with every overview poll.  The panel hangs its
          -- sidebar badges off these.
          "health" .= addObjectFields ["warn_logs" .= warned] health
        ]
  RConversations -> ok . map conversationJson <$> listConversations
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
      mems <- listMemories (groupMemoryNamespace (conversationScopeFor (GroupId gid)))
      pure (ok (map (memoryJson Nothing) mems))
    (Just "user", Just uid) -> do
      mems <- listUserMemoriesEverywhereAdmin uid
      pure (ok (map (\(m, src) -> memoryJson src m) mems))
    _ -> pure (bad "expected ?scope=group|user&id=<qq/群号>")
  RMemoryDelete mid -> do
    let memoryId = MemoryId mid
        actor = MemoryActor ActorAdmin Nothing (Just "admin API archive")
    fetchMemoryAdmin memoryId >>= \case
      Nothing -> pure notFound
      Just item ->
        archiveMemoryAdmin actor memoryId (ExpectedVersion item.memVersion) >>= \case
          MemoryMutationApplied _ -> pure deleted
          MemoryMutationRejected -> pure notFound
  -- ?group=<gid> narrows to what that group's dispatches can see
  -- (global + own, before enabled-filtering/shadowing); without it,
  -- every row.
  RSkillsList -> do
    skills <- liftIO (listAllSkills env.beSkills)
    let wanted = case intParam "group" of
          Nothing -> skills
          Just g -> [s | s <- skills, maybe True (== g) s.skillGroup]
    pure (ok (map skillJson wanted))
  RSkillCreate ->
    case A.eitherDecode body :: Either String PostSkill of
      Left err -> pure (bad ("invalid json: " <> T.pack err))
      Right ps -> do
        res <-
          createSkill
            env.beSkills
            NewSkill
              { nsName = T.strip ps.psName,
                nsGroup = ps.psGroup,
                nsDescription = T.strip ps.psDescription,
                nsBody = ps.psBody,
                nsEnabled = ps.psEnabled,
                -- NULL marks rows minted here rather than taught from
                -- chat; 0 marks a row minted here rather than by a user.
                nsCreatedBy = Nothing
              }
        case res of
          Left err -> pure (bad err)
          Right s -> do
            logInfo "admin: skill created" $ object ["id" .= s.skillId, "name" .= s.skillName]
            pure (ok (skillJson s))
  -- The plan kernel's only entry has always been a model deciding to call
  -- @plan_run@, and in production it has decided to once, ever.  So the thing
  -- worth building was not another way to /run/ a plan — it was a way to ask
  -- why one would not be accepted, against this binary's live catalog rather
  -- than a test fixture.
  --
  -- Deliberately parse and validate only.  Executing from here would need the
  -- Agent, LLM and Outbound rows this server does not have, and a turn minted
  -- on behalf of nobody in somebody's conversation; that is a much larger
  -- authority question than a syntax check, and it should not arrive as a side
  -- effect of one.
  RPlanCheck ->
    case A.eitherDecode body :: Either String PostPlanCheck of
      Left err -> pure (bad ("invalid json: " <> T.pack err))
      Right pc -> do
        let gid = GroupId pc.ppcGroupId
            -- The gates a fresh turn in that conversation would open with.  A
            -- plan is checked against the catalog it would actually meet, so a
            -- tool missing here is missing for the same reason it would be
            -- missing then.
            caps =
              TurnCapabilities
                { tcMultimodal = fromMaybe True pc.ppcMultimodal,
                  tcStickers = False,
                  tcSkills = False,
                  tcOutput = noAdvertisedCaps,
                  tcMonitorArming = False,
                  tcCatalogGrants = Map.empty,
                  tcEffectCeiling = Nothing,
                  tcSubgoal = Nothing
                }
            catalog = planCatalog (toolDefinitionsFor env gid caps)
            objective = T.strip pc.ppcObjective
            root = "plan:" <> T.take 12 (T.filter (/= ' ') objective)
        pure $ case parsePlan pc.ppcPlan of
          Left failure -> ok (checkResult "parse" (parseFailureText failure) catalog)
          Right parsed ->
            -- No resource bodies: nothing has been resolved because nothing is
            -- being run, so a plan naming a handle is rejected here and would
            -- not be at dispatch.  Reported as the stage it failed at rather
            -- than smoothed over.
            case validatePlan (validationEnvForContract catalog objective Nothing mempty) root parsed of
              Left rejection -> ok (checkResult "validate" (rejectionText rejection) catalog)
              Right _ ->
                ok
                  ( A.object
                      [ "ok" .= True,
                        "root" .= root,
                        "hash" .= planHash parsed,
                        "holes" .= length (planHoles root parsed),
                        "children" .= length (planChildren root parsed),
                        "catalog" .= catalogNames catalog
                      ]
                  )
  RSkillPatch sid ->
    case A.eitherDecode body of
      Left err -> pure (bad ("invalid json: " <> T.pack err))
      Right (Object o) -> applySkillPatch env sid o
      Right _ -> pure (bad "body must be a json object")
  RSkillDelete sid -> do
    gone <- deleteSkill env.beSkills sid
    if gone
      then do
        logInfo "admin: skill deleted" $ object ["id" .= sid]
        pure deleted
      else pure notFound
  RTasksList -> do
    tasks <- liftIO (listTasks env.beTasks Nothing)
    pure (ok (map taskJson tasks))
  RTaskKill tid -> do
    killed <- liftIO (cancelTask env.beTasks (TaskId tid))
    pure (if killed then deleted else notFound)
  RUsage -> do
    let days = clamp (1, 365) (fromMaybe 30 (intParam "days"))
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
  -- The only endpoint whose answer lives in another process, so it is
  -- also the only one that can be up while its data source is down —
  -- hence the 502 rather than an empty list, which would read as
  -- "pool is fine, nothing in it".
  RQuota -> case env.beCliProxy of
    Nothing ->
      pure . ok $
        object ["configured" .= False, "credentials" .= ([] :: [Value])]
    Just cp ->
      fetchCredentials cp >>= \case
        Left err ->
          pure . jsonResponse status502 $
            object
              [ "configured" .= True,
                "base_url" .= cp.cpBaseUrl,
                "error" .= err
              ]
        Right creds ->
          pure . ok $
            object
              [ "configured" .= True,
                "base_url" .= cp.cpBaseUrl,
                "credentials" .= map credentialJson creds
              ]
  RMessageStats -> do
    let days = clamp (1, 365) (fromMaybe 14 (intParam "days"))
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
            lqLimit = clamp (1, 1000) (fromMaybe 200 (intParam "limit"))
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
          "latest" .= ((.leSeq) <$> listToMaybe entries)
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
        (clamp (1, 200) (fromMaybe 50 (intParam "limit")))
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
  RPlatformStatus -> ok <$> listPlatformStatus
  RPlatformTimeline legacyConversation -> do
    timeline <-
      loadAdminTimeline
        legacyConversation
        (intParam "after")
        (clamp (1, 200) (fromMaybe 100 (intParam "limit")))
    pure (maybe notFound ok timeline)
  RPlatformTimelineWait legacyConversation -> case (intParam "after", intParam "revision") of
    (Nothing, _) -> pure (bad "expected ?after=<conversation_seq>")
    (_, Nothing) -> pure (bad "expected ?revision=<timeline_revision>")
    (Just after, Just revision) -> do
      changed <- waitAdminTimeline legacyConversation after revision
      timeline <-
        loadAdminTimeline
          legacyConversation
          (if changed then Nothing else Just after)
          (clamp (1, 200) (fromMaybe 200 (intParam "limit")))
      pure . maybe notFound ok $
        case timeline of
          Just (Object fields) -> Just (Object (KM.insert "replace" (Bool changed) fields))
          other -> other
  RBlob sha -> case blobRefFromSha256 sha of
    Nothing -> pure notFound
    Just ref ->
      trySync (readBlob ref) >>= \case
        Left _ -> pure notFound
        Right bytes ->
          pure $
            responseLBS
              status200
              [ (hContentType, "application/octet-stream"),
                (hCacheControl, "private, max-age=31536000, immutable")
              ]
              (LBS.fromStrict bytes)
  RContextStatus -> do
    status <- loadContextStatus (intParam "group")
    pure . ok $
      case status of
        Object fields ->
          Object $
            fields
              <> KM.fromList
                [ "historian_profile" .= env.beMemoryExtract,
                  "force_raw_context" .= env.beForceRawContext
                ]
        value -> value
  RContextCaptures -> do
    rows <- listCaptureRunsAdmin (intParam "group") (clamp (1, 500) (fromMaybe 100 (intParam "limit")))
    pure (ok rows)
  RContextCompartments -> do
    rows <- listCompartmentsAdmin (intParam "group") (clamp (1, 500) (fromMaybe 100 (intParam "limit")))
    pure (ok rows)
  RContextPlans -> do
    rows <- listPlanTracesAdmin (intParam "group") (clamp (1, 200) (fromMaybe 50 (intParam "limit")))
    pure (ok rows)
  RContextMemory mid ->
    fetchMemoryHistoryAdmin (MemoryId mid) >>= \case
      Nothing -> pure notFound
      Just detail -> pure (ok detail)
  RContextEmbeddings ->
    embeddingSpace >>= \case
      Nothing -> do
        status <- loadEmbeddingStatus "(disabled)" (intParam "group")
        pure . ok $ addObjectFields ["configured" .= False] status
      Just space -> do
        status <- loadEmbeddingStatus space.esModelId (intParam "group")
        pure . ok $ addObjectFields ["configured" .= True] status
  RContextRecall -> case (intParam "group", nonBlank =<< lookup "q" params) of
    (Just groupId, Just recallQuery) -> do
      (embedding, embeddingError) <- recallEmbedding recallQuery
      trace <-
        searchRecallTrace
          (currentConversationRecall (conversationScopeFor (GroupId groupId)))
          (Set.fromList [minBound .. maxBound])
          recallQuery
          embedding
          (clamp (1, 30) (fromMaybe 10 (intParam "limit")))
      pure . ok $ addObjectFields ["embedding_error" .= embeddingError] (recallTraceJson trace)
    _ -> pure (bad "expected ?group=<conversation>&q=<query>")
  RContextIntegrity -> ok <$> runContextIntegrityCheck (intParam "group")
  RContextRebuild ->
    case A.eitherDecode body :: Either String PostContextRebuild of
      Left err -> pure (bad ("invalid json: " <> T.pack err))
      Right request -> case env.beMemoryExtract of
        Nothing -> pure (bad "Historian is disabled; configure memory.extract_profile first")
        Just profile -> do
          now <- liftIO getCurrentTime
          runs <-
            enqueueContextRebuildAdmin
              request.pcrConversationId
              (CompartmentId <$> request.pcrCompartmentId)
              profile
              ("admin:" <> T.pack (show now))
          if null runs
            then pure notFound
            else
              pure . ok $
                object
                  [ "enqueued"
                      .= [ object
                             [ "capture_run_id" .= run.crId,
                               "conversation_id" .= run.crConversationId,
                               "start_ingest_seq" .= run.crRange.srStart.ingestSeq,
                               "end_ingest_seq" .= run.crRange.srEnd.ingestSeq,
                               "replaces_compartment_id" .= run.crReplacesCompartment
                             ]
                         | run <- runs
                         ]
                  ]
  RContextReindex ->
    case A.eitherDecode body :: Either String PostContextReindex of
      Left err -> pure (bad ("invalid json: " <> T.pack err))
      Right request
        | any (`notElem` ["message", "memory", "episode"]) request.pciCorpora ->
            pure (bad "corpora must contain only message, memory, or episode")
        | otherwise ->
            invalidateEmbeddingsAdmin request.pciConversationId request.pciCorpora >>= \case
              Left err -> pure (jsonResponse status409 (object ["error" .= err]))
              Right result -> pure (ok result)
  -- Answered by 'staticResponse' before the effectful handler is
  -- entered (it needs no database and no unlift); listed so the match
  -- stays total if that ever changes.
  RStatic p -> pure (staticResponse p)
  where
    nonBlank t = if T.null (T.strip t) then Nothing else Just (T.strip t)
    ok :: (A.ToJSON a) => a -> Response
    ok = jsonResponse status200
    bad msg = jsonResponse status400 (object ["error" .= (msg :: Text)])
    notFound = jsonResponse status404 (object ["error" .= ("not found" :: Text)])
    deleted = jsonResponse status200 (object ["deleted" .= True])
    intParam :: (Integral a) => Text -> Maybe a
    intParam k = do
      v <- lookup k params
      case TR.signed TR.decimal v of
        Right (n, "") -> Just n
        _ -> Nothing

-- | The accounts the bot itself is logged in as, one row per platform.
botAccounts :: (WithConnection :> es, IOE :> es) => Eff es [Value]
botAccounts = do
  rows <-
    query
      "SELECT platform, native_account_id, display_name, enabled \
      \ FROM platform_accounts ORDER BY platform, platform_account_id"
      ()
  pure
    [ object
        [ "platform" .= platform,
          "native_account_id" .= native,
          "display_name" .= display,
          "enabled" .= enabled
        ]
    | (platform, native, display, enabled) <-
        rows :: [(Text, Text, Maybe Text, Bool)]
    ]

-- | The counters worth a badge: work that is stuck rather than work
-- that is merely queued.  One round trip, four index-backed counts.
healthCounters :: (WithConnection :> es, IOE :> es) => Eff es Value
healthCounters = do
  rows <-
    query
      "SELECT \
      \  (SELECT count(*) FROM message_deliveries WHERE status = 'failed'), \
      \  (SELECT count(*) FROM message_deliveries WHERE status = 'outcome_unknown'), \
      \  (SELECT count(*) FROM episode_capture_runs WHERE status = 'failed'), \
      \  (SELECT count(*) FROM fetch_jobs WHERE parked_at IS NULL), \
      \  (SELECT count(*) FROM fetch_jobs WHERE parked_at IS NOT NULL)"
      ()
  pure $ case rows :: [(Int64, Int64, Int64, Int64, Int64)] of
    [(failed, unknown, captures, pending, parked)] ->
      object
        [ "failed_deliveries" .= failed,
          "unknown_deliveries" .= unknown,
          "failed_captures" .= captures,
          "media_pending" .= pending,
          "media_parked" .= parked
        ]
    _ -> object []

-- | A conversation as a picker wants it: what to call it, what it is,
-- and how recently it mattered.
conversationJson :: ConversationSummary -> Value
conversationJson c =
  object
    [ "conversation_id" .= c.csConversationId,
      "legacy_group_id" .= c.csLegacyGroupId,
      "kind" .= c.csKind,
      "title" .= c.csTitle,
      "platforms" .= maybe [] (T.splitOn ",") c.csPlatforms,
      "endpoints" .= c.csEndpoints,
      "message_count" .= c.csMessageCount,
      "last_message_at" .= c.csLastMessageAt
    ]

addObjectFields :: [Pair] -> Value -> Value
addObjectFields fields = \case
  Object objectValue -> Object (objectValue <> KM.fromList fields)
  value -> value

recallEmbedding :: (Embedding :> es) => Text -> Eff es (Maybe EmbeddingRecord, Maybe Text)
recallEmbedding recallQuery =
  embedBatch [recallQuery] >>= \case
    Left fault -> pure (Nothing, Just (renderEmbeddingFault fault))
    Right [record] -> pure (Just record, Nothing)
    Right _ -> pure (Nothing, Just "embedding provider returned an unexpected result count")

recallTraceJson :: RecallTrace -> Value
recallTraceJson trace =
  object
    [ "conversation_id" .= trace.rtConversationId,
      "query" .= trace.rtQuery,
      "requested_corpora" .= trace.rtRequestedCorpora,
      "policy_filter" .= ("current conversation visibility applied in SQL before candidate ranking" :: Text),
      "result_limit" .= trace.rtResultLimit,
      "lexical_candidates" .= trace.rtLexicalCandidates,
      "semantic_candidates" .= trace.rtSemanticCandidates,
      "corpus_filtered_candidates" .= trace.rtCorpusFilteredCandidates,
      "merged_candidates" .= trace.rtMergedCandidates,
      "source_quotas" .= object [Key.fromText source .= quota | (source, quota) <- trace.rtSourceQuotas],
      "candidates" .= map recallTraceCandidateJson trace.rtCandidates,
      "selected" .= map recallHitJson trace.rtSelected
    ]

recallTraceCandidateJson :: RecallTraceCandidate -> Value
recallTraceCandidateJson traced =
  addObjectFields
    [ "final_score" .= traced.rtcScore,
      "decision" .= traced.rtcDecision
    ]
    (recallCandidateJson traced.rtcCandidate)

recallCandidateJson :: RecallCandidate -> Value
recallCandidateJson candidate =
  object
    [ "source" .= candidate.rcSource,
      "dedup_key" .= candidate.rcDedupKey,
      "snippet" .= candidate.rcSnippet,
      "occurred_at" .= candidate.rcOccurredAt,
      "principal_id" .= candidate.rcPrincipalId,
      "message_id" .= candidate.rcMessageId,
      "episode_handle" .= fmap episodeHandleText candidate.rcEpisodeHandle,
      "memory_id" .= candidate.rcMemoryId,
      "importance" .= candidate.rcImportance,
      "lexical_score" .= candidate.rcLexicalScore,
      "semantic_score" .= candidate.rcSemanticScore,
      "pinned" .= candidate.rcPinned,
      "permanent" .= candidate.rcPermanent
    ]

recallHitJson :: RecallHit -> Value
recallHitJson hit =
  object
    [ "source" .= hit.rhSource,
      "dedup_key" .= hit.rhDedupKey,
      "snippet" .= hit.rhSnippet,
      "occurred_at" .= hit.rhOccurredAt,
      "principal_id" .= hit.rhPrincipalId,
      "message_id" .= hit.rhMessageId,
      "episode_handle" .= fmap episodeHandleText hit.rhEpisodeHandle,
      "memory_id" .= hit.rhMemoryId,
      "score" .= hit.rhScore,
      "lexical_score" .= hit.rhLexicalScore,
      "semantic_score" .= hit.rhSemanticScore,
      "pinned" .= hit.rhPinned,
      "permanent" .= hit.rhPermanent
    ]

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
        k `elem` (["model", "persona", "debug", "sticker", "proactive", "effort"] :: [Text])
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
      ("effort", String e) -> Right (\s -> s {effortOverride = Just e})
      ("effort", Null) -> Right (\s -> s {effortOverride = Nothing})
      (k, _) -> Left ("bad value for field: " <> k)

-- | Apply a skill PATCH through the registry.  Same field semantics
-- as the session patch: absent = untouched, @null@ = clear (only
-- @group_id@ is clearable — that's "make it global"), value = set.
-- Validation and duplicate-name rejection live in
-- 'Max.Skills.updateSkill'.
applySkillPatch ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  BotEnv ->
  Int64 ->
  A.Object ->
  Eff es Response
applySkillPatch env sid o =
  case edits of
    Left err -> pure (jsonResponse status400 (object ["error" .= err]))
    Right [] -> pure (jsonResponse status400 (object ["error" .= ("no recognised fields" :: Text)]))
    Right es ->
      updateSkill env.beSkills sid (\s -> foldl (flip ($)) s es) >>= \case
        Left "not found" -> pure (jsonResponse status404 (object ["error" .= ("not found" :: Text)]))
        Left err -> pure (jsonResponse status400 (object ["error" .= err]))
        Right s -> do
          logInfo "admin: skill patched" $
            object ["id" .= sid, "fields" .= map fst recognised]
          pure (jsonResponse status200 (skillJson s))
  where
    recognised =
      [ (k, v)
      | (key, v) <- KM.toList o,
        let k = Key.toText key,
        k `elem` (["name", "group_id", "description", "body", "enabled"] :: [Text])
      ]
    edits :: Either Text [Skill -> Skill]
    edits = traverse toEdit recognised
    toEdit = \case
      ("name", String n) -> Right (\s -> s {skillName = T.strip n})
      ("group_id", v@(Number _)) -> case A.fromJSON v of
        A.Success (g :: Int64) -> Right (\s -> s {skillGroup = Just g})
        A.Error e -> Left ("bad value for field: group_id (" <> T.pack e <> ")")
      ("group_id", Null) -> Right (\s -> s {skillGroup = Nothing})
      ("description", String d) -> Right (\s -> s {skillDescription = T.strip d})
      ("body", String b) -> Right (\s -> s {skillBody = b})
      ("enabled", Bool b) -> Right (\s -> s {skillEnabled = b})
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
      "effort" .= s.effortOverride
    ]

memoryJson :: Maybe Int64 -> MemoryItem -> Value
memoryJson sourceGroup m =
  object
    [ "id" .= m.memId,
      "version" .= m.memVersion,
      "scope" .= m.memScope,
      "scope_id" .= m.memScopeId,
      "content" .= m.memContent,
      "lifecycle" .= m.memLifecycle,
      "category" .= m.memCategory,
      "updated_at" .= m.memUpdatedAt,
      "source_group_id" .= sourceGroup
    ]

skillJson :: Skill -> Value
skillJson s =
  object
    [ "id" .= s.skillId,
      -- Negative ids ship inside the binary (skills/*.md) and are
      -- immutable through this API; a DB skill with the same name
      -- overrides one.
      "builtin" .= (s.skillId < 0),
      "name" .= s.skillName,
      "group_id" .= s.skillGroup,
      "description" .= s.skillDescription,
      "body" .= s.skillBody,
      "enabled" .= s.skillEnabled,
      "created_by" .= s.skillCreatedBy,
      "updated_at" .= s.skillUpdatedAt
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
      "progress_at" .= ti.tiProgressAt,
      "pending_notes" .= ti.tiPending
    ]

-- | Body of @POST /api/skills@.
data PostSkill = PostSkill
  { psName :: !Text,
    psGroup :: !(Maybe Int64),
    psDescription :: !Text,
    psBody :: !Text,
    psEnabled :: !Bool
  }

instance A.FromJSON PostSkill where
  parseJSON = A.withObject "skill" $ \o ->
    PostSkill
      <$> o A..: "name"
      <*> o A..:? "group_id"
      <*> o A..: "description"
      <*> o A..: "body"
      <*> (fromMaybe True <$> o A..:? "enabled")

-- | Body of @POST /api/plan/check@.
data PostPlanCheck = PostPlanCheck
  { -- | Which conversation's gates to check against; the catalog differs by
    -- private-vs-group and by what the profile can see.
    ppcGroupId :: !Int64,
    ppcObjective :: !Text,
    ppcPlan :: !Text,
    -- | Defaults to the wider catalog, because a check that quietly hides the
    -- browser tools would answer a question nobody asked.
    ppcMultimodal :: !(Maybe Bool)
  }

instance A.FromJSON PostPlanCheck where
  parseJSON = A.withObject "plan check" $ \o ->
    PostPlanCheck
      <$> o A..: "group_id"
      <*> (fromMaybe "" <$> o A..:? "objective")
      <*> o A..: "plan"
      <*> o A..:? "multimodal"

-- | Which stage refused it, and what the catalog looked like when it did.
--
-- The catalog is in every answer, including the failures: "no such tool" and
-- "that tool is not plannable" read identically to whoever wrote the plan, and
-- the list is what tells them apart.
checkResult :: Text -> Text -> Map ToolRef entry -> A.Value
checkResult stage detail catalog =
  A.object
    [ "ok" .= False,
      "stage" .= stage,
      "error" .= detail,
      "catalog" .= catalogNames catalog
    ]

catalogNames :: Map ToolRef entry -> [Text]
catalogNames = map (.unToolRef) . Map.keys

data PostContextRebuild = PostContextRebuild
  { pcrConversationId :: !Int64,
    pcrCompartmentId :: !(Maybe Int64)
  }

instance A.FromJSON PostContextRebuild where
  parseJSON = A.withObject "context rebuild" $ \o ->
    PostContextRebuild
      <$> o A..: "conversation_id"
      <*> o A..:? "compartment_id"

data PostContextReindex = PostContextReindex
  { pciConversationId :: !Int64,
    pciCorpora :: ![Text]
  }

instance A.FromJSON PostContextReindex where
  parseJSON = A.withObject "context reindex" $ \o ->
    PostContextReindex
      <$> o A..: "conversation_id"
      <*> (fromMaybe ["memory"] <$> o A..:? "corpora")
