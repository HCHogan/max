{-# LANGUAGE TypeFamilies #-}

-- | Injectable embedding boundary shared by recall, tools, admin diagnostics,
-- and the background backfill worker.  Transport/provider details stay in the
-- production interpreter; callers receive validated records with explicit
-- model-space provenance.
module Max.Effects.Embedding
  ( Embedding,
    EmbeddingSpace (..),
    EmbeddingFaultKind (..),
    EmbeddingFault (..),
    runEmbedding,
    runRuntimeEmbedding,
    runEmbeddingWith,
    embedBatch,
    embeddingSpace,
    renderEmbeddingFault,
  )
where

import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Reader.Dynamic (Reader, ask)
import Max.Embedding
  ( EmbedClient,
    EmbeddingRecord (..),
    embedTexts,
    embeddingModelId,
    makeEmbeddingRecord,
  )
import Max.Env (BotEnv (..))
import Max.RuntimeConfig (RuntimeResources (..), RuntimeSnapshot (..))

data EmbeddingSpace = EmbeddingSpace
  { esModelId :: !Text
  }
  deriving stock (Show, Eq)

data EmbeddingFaultKind
  = EmbeddingDisabled
  | EmbeddingTransport
  | EmbeddingInvalidShape
  | EmbeddingInvalidVector
  deriving stock (Show, Eq)

data EmbeddingFault = EmbeddingFault
  { efKind :: !EmbeddingFaultKind,
    efMessage :: !Text
  }
  deriving stock (Show, Eq)

data Embedding :: Effect where
  EmbedBatch :: [Text] -> Embedding m (Either EmbeddingFault [EmbeddingRecord])
  GetEmbeddingSpace :: Embedding m (Maybe EmbeddingSpace)

type instance DispatchOf Embedding = Dynamic

runEmbedding ::
  (IOE :> es) =>
  Maybe EmbedClient ->
  Eff (Embedding : es) a ->
  Eff es a
runEmbedding mClient =
  runEmbeddingResolving (pure mClient)

-- | Resolve the client from the immutable snapshot in the current Reader
-- scope.  Dispatches install their leased snapshot; generation workers install
-- the snapshot they were started for.  This keeps endpoint credentials and
-- model-space provenance on the same side of the publication boundary.
runRuntimeEmbedding ::
  (Reader BotEnv :> es, IOE :> es) =>
  Eff (Embedding : es) a ->
  Eff es a
runRuntimeEmbedding =
  runEmbeddingResolving $ do
    env <- ask @BotEnv
    pure env.beRuntimeSnapshot.rsResources.rrEmbeddingClient

runEmbeddingResolving ::
  (IOE :> es) =>
  Eff es (Maybe EmbedClient) ->
  Eff (Embedding : es) a ->
  Eff es a
runEmbeddingResolving resolve = interpret $ \_ -> \case
  GetEmbeddingSpace -> do
    mClient <- resolve
    pure (EmbeddingSpace . embeddingModelId <$> mClient)
  EmbedBatch texts -> do
    mClient <- resolve
    case mClient of
      Nothing -> pure (Left (EmbeddingFault EmbeddingDisabled "embedding is not configured"))
      Just client -> do
        raw <- liftIO (embedTexts client texts)
        pure $ case raw of
          Left err -> Left (EmbeddingFault EmbeddingTransport err)
          Right vectors
            | length vectors /= length texts ->
                Left (EmbeddingFault EmbeddingInvalidShape "embedding provider returned an unexpected result count")
            | otherwise ->
                case traverse (uncurry (makeEmbeddingRecord client)) (zip texts vectors) of
                  Left err -> Left (EmbeddingFault EmbeddingInvalidVector err)
                  Right records
                    | consistentDimensions records -> Right records
                    | otherwise ->
                        Left (EmbeddingFault EmbeddingInvalidShape "embedding batch contains inconsistent dimensions")

runEmbeddingWith ::
  Maybe EmbeddingSpace ->
  ([Text] -> Eff es (Either EmbeddingFault [EmbeddingRecord])) ->
  Eff (Embedding : es) a ->
  Eff es a
runEmbeddingWith space runBatch = interpret $ \_ -> \case
  EmbedBatch texts -> runBatch texts
  GetEmbeddingSpace -> pure space

embedBatch :: (Embedding :> es) => [Text] -> Eff es (Either EmbeddingFault [EmbeddingRecord])
embedBatch = send . EmbedBatch

embeddingSpace :: (Embedding :> es) => Eff es (Maybe EmbeddingSpace)
embeddingSpace = send GetEmbeddingSpace

renderEmbeddingFault :: EmbeddingFault -> Text
renderEmbeddingFault fault =
  kind <> ": " <> fault.efMessage
  where
    kind = case fault.efKind of
      EmbeddingDisabled -> "disabled"
      EmbeddingTransport -> "transport"
      EmbeddingInvalidShape -> "invalid-shape"
      EmbeddingInvalidVector -> "invalid-vector"

consistentDimensions :: [EmbeddingRecord] -> Bool
consistentDimensions [] = True
consistentDimensions (first : rest) = all ((== first.erDimensions) . (.erDimensions)) rest
