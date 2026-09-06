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
import Max.Embedding
  ( EmbedClient,
    EmbeddingRecord (..),
    embedTexts,
    embeddingModelId,
    makeEmbeddingRecord,
  )

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
runEmbedding mClient = runRuntimeEmbedding (pure mClient)

-- | Assembly supplies a client resolver evaluated once per operation, so a
-- dispatch can retain its leased generation while the effect knows only the
-- embedding client. Do not capture a process-start snapshot for live reload.
runRuntimeEmbedding ::
  (IOE :> es) =>
  Eff es (Maybe EmbedClient) ->
  Eff (Embedding : es) a ->
  Eff es a
runRuntimeEmbedding resolve = interpret $ \_ -> \case
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
