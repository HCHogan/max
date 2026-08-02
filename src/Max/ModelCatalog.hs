-- |
-- Immutable, read-only model catalog, materialized once from configuration.
--
-- This public module exposes only profile identity and prompt-facing
-- capabilities. Endpoint credentials and provider transport settings live in
-- a Cabal-hidden internal module used only by configuration and LLM execution.
module Max.ModelCatalog
  ( ModelCatalog,
    ModelCatalogError (..),
    ContextLimits (..),
    defaultContextLimits,
    contextInputBudget,
    ModelCapabilities (..),
    mkModelCatalog,
    defaultModelName,
    modelProfileNames,
    lookupModelCapabilities,
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Max.ModelCatalog.Internal
  ( ContextLimits (..),
    ModelCapabilities (..),
    ModelCatalog,
    ModelCatalogError (..),
    contextInputBudget,
    defaultContextLimits,
    defaultModelName,
    lookupModelCapabilities,
    mkModelCatalogFromCapabilities,
    modelProfileNames,
  )

-- | Construct a capability-only catalog. This is useful for pure consumers
-- and their tests; production configuration uses the hidden completion-aware
-- constructor and derives this same safe view from each full profile.
mkModelCatalog :: Text -> Map Text ModelCapabilities -> Either ModelCatalogError ModelCatalog
mkModelCatalog = mkModelCatalogFromCapabilities
