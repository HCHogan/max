{-# LANGUAGE TypeFamilies #-}

-- | Browser protocol operations scoped by the host, without session ids,
-- launch settings, registry access or arbitrary MCP method names.
module Max.Effects.Browser (Browser, BrowserOperation (..), SessionMethod (..), navigateUrlWith, sessionRequest, readZhihu, runBrowser) where

import Data.Aeson (Key, Value)
import Data.Text (Text)
import Effectful
  ( Dispatch (Dynamic),
    DispatchOf,
    Eff,
    Effect,
    type (:>),
  )
import Effectful.Dispatch.Dynamic (interpret, send)

data SessionMethod = SessionSnapshot | SessionInspect | SessionAction deriving stock (Eq, Show)

data BrowserOperation = Navigate !Text ![(Key, Value)] | Session !SessionMethod ![(Key, Value)] | ReadZhihu !Text

data Browser :: Effect where
  BrowserOperation :: BrowserOperation -> Browser m (Either Text Value)

type instance DispatchOf Browser = Dynamic

navigateUrlWith :: (Browser :> es) => Text -> [(Key, Value)] -> Eff es (Either Text Value)
navigateUrlWith url fields = send (BrowserOperation (Navigate url fields))

sessionRequest :: (Browser :> es) => SessionMethod -> [(Key, Value)] -> Eff es (Either Text Value)
sessionRequest method fields = send (BrowserOperation (Session method fields))

readZhihu :: (Browser :> es) => Text -> Eff es (Either Text Value)
readZhihu url = send (BrowserOperation (ReadZhihu url))

runBrowser :: (BrowserOperation -> Eff es (Either Text Value)) -> Eff (Browser : es) a -> Eff es a
runBrowser handle = interpret $ \_ -> \case
  BrowserOperation operation -> handle operation
