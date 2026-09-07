{-# LANGUAGE TypeFamilies #-}

-- | Read-only discovery of the validated catalog. This interpreter is pure:
-- neither model schema discovery nor diagnostics require execution capability.
module Max.Effects.ToolDirectory
  ( ToolDirectory,
    runToolDirectory,
    runToolDirectoryDynamic,
    listToolSpecs,
    listCatalogTools,
  )
where

import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Tool.Catalog (ToolCatalog, catalogSpecs, catalogTools)
import Max.Tool.Types (CatalogTool, ToolSpec)

data ToolDirectory :: Effect where
  ListToolSpecs :: ToolDirectory m [ToolSpec]
  ListCatalogTools :: ToolDirectory m [CatalogTool]

type instance DispatchOf ToolDirectory = Dynamic

runToolDirectory :: ToolCatalog -> Eff (ToolDirectory : es) a -> Eff es a
runToolDirectory catalog = runToolDirectoryDynamic (pure catalog)

runToolDirectoryDynamic :: Eff es ToolCatalog -> Eff (ToolDirectory : es) a -> Eff es a
runToolDirectoryDynamic currentCatalog = interpret $ \_ -> \case
  ListToolSpecs -> catalogSpecs <$> currentCatalog
  ListCatalogTools -> catalogTools <$> currentCatalog

listToolSpecs :: (ToolDirectory :> es) => Eff es [ToolSpec]
listToolSpecs = send ListToolSpecs

listCatalogTools :: (ToolDirectory :> es) => Eff es [CatalogTool]
listCatalogTools = send ListCatalogTools
