{-# LANGUAGE TypeFamilies #-}

module Max.Effects.HookQuery (HookQuery, queryHooks, runHookQuery) where

import Data.Aeson (Value)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (ConversationScope, conversationStorageId)
import Max.DB.Hook qualified as DB
import Max.Hook.Types qualified as Types

data HookQuery :: Effect where
  QueryHooks :: Types.HookQuery -> HookQuery m (Either Text Value)

type instance DispatchOf HookQuery = Dynamic

queryHooks :: (HookQuery :> es) => Types.HookQuery -> Eff es (Either Text Value)
queryHooks = send . QueryHooks

runHookQuery :: (WithConnection :> es, IOE :> es) => ConversationScope -> Bool -> Eff (HookQuery : es) a -> Eff es a
runHookQuery scope administrator = interpret $ \_ -> \case
  QueryHooks request
    | administrator -> DB.queryHooks (conversationStorageId scope) request
    | otherwise -> pure (Left "group_administrator_required")
