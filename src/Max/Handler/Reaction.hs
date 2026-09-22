module Max.Handler.Reaction
  ( queueQQReaction,
    deniedFaceId,
    processingFaceId,
    ackFaceId,
    failureFaceId,
    defaultSilenceFace,
  )
where

import Data.Foldable (for_)
import Data.Text qualified as T
import Effectful (Eff, IOE, MonadIO (liftIO), type (:>))
import Effectful.Exception (SomeException)
import Effectful.Log (Log, logAttention, object, (.=))
import Effectful.PostgreSQL (WithConnection)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Env (BotEnv (..))
import Max.Platform.Delivery.Queue (queueDeliveries)
import Max.Platform.Store.Outbound
  ( EnqueuedReaction (deliveries),
    ReactionDraft (..),
    enqueueReaction,
  )
import Max.Platform.Types
  ( CanonicalMessageId (CanonicalMessageId),
    Platform (PlatformQQ),
    ReactionAction (ReactionAdd, ReactionRemove),
  )
import Max.Util (trySync)
import OneBot.Types (GroupId (..))

-- | Enqueue a canonical reaction; the delivery worker resolves the native copy.
-- Missing or unsupported targets are ignored, and failures stay local.
queueQQReaction ::
  (Reader BotEnv :> es, WithConnection :> es, Log :> es, IOE :> es) =>
  GroupId ->
  CanonicalMessageId ->
  Int ->
  Bool ->
  Eff es ()
queueQQReaction (GroupId group) (CanonicalMessageId message) faceId added =
  trySync
    ( enqueueReaction
        ReactionDraft
          { legacyConversationId = group,
            targetCanonicalMessageId = message,
            reactionKey = T.pack (show faceId),
            reactionAction = if added then ReactionAdd else ReactionRemove,
            requiredPlatform = Just PlatformQQ
          }
    )
    >>= \case
      Right result -> do
        env :: BotEnv <- ask
        for_ result (liftIO . queueDeliveries env.beDeliveries . (.deliveries))
      Left e ->
        logAttention "reaction publication failed" $
          object
            [ "group_id" .= group,
              "message_id" .= message,
              "face_id" .= faceId,
              "added" .= added,
              "error" .= T.pack (show (e :: SomeException))
            ]

-- | QQ NO: permission denied.
deniedFaceId :: Int
deniedFaceId = 123

-- | QQ 托腮: processing. IDs use NapCat face_config.json QSid.
processingFaceId :: Int
processingFaceId = 212

-- | QQ OK: command acknowledged.
ackFaceId :: Int
ackFaceId = 124

-- | QQ 裂开: execution failed; distinct from a refused request.
failureFaceId :: Int
failureFaceId = 357

-- | QQ 闭嘴: direct-trigger silence without a recognized reason face.
defaultSilenceFace :: Int
defaultSilenceFace = 7
