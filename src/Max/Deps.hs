-- |
-- App-wide wiring threaded from 'Main' through the event handler and
-- background workers. New per-app resources land here as later phases
-- arrive.
--
-- == Worker / queue topology (Phase 3)
--
-- @
--                   NapCat (WS client)
--                          │
--                          ▼
--   ┌─── OneBot.Server (one acceptConn per reconnect) ──────────────┐
--   │                                                                │
--   │   per-connection:                                              │
--   │     ┌──────────────────────────────────────────┐               │
--   │     │  readLoop  ──► events ──► TQueue Event   │               │
--   │     │              responses ─► pending TMVars │               │
--   │     │  handler   ◄─ TQueue Event               │               │
--   │     └──────────────────────────────────────────┘               │
--   │             │                  ▲                               │
--   │   setClient │                  │ call (await response)         │
--   │      Just/Nothing              │                               │
--   │             ▼                  │                               │
--   └─── TVar (Maybe Client) ◄───────┴──────────── Max.Forward ──────┘
--                                                       │
--                                                       │ get_forward_msg
--                                                       ▼
--   handler ──► insertGroupMessage (sync, fast)
--           ├─► enqueueImages   ──► TQueue ImageJob   ──► Max.Images worker
--           │                                                │
--           │                                                ▼
--           │                                          download + sha256
--           │                                          + write blob + DB
--           │
--           └─► enqueueForwards ──► TQueue ForwardJob ──► Max.Forward worker
--                                                              │
--                                                              ▼
--                                                  call(GetForwardMsg)
--                                                  parse nodes
--                                                  insertForwardNode (synthetic id)
--                                                  recurse:
--                                                    ├─► nested forward → fwdQ
--                                                    └─► node images   → imgQ
-- @
--
-- Both background workers are app-lived; the WS connection comes and goes
-- under them. Workers read 'clientRef' to find the live 'Client' and bail
-- out cleanly when there isn't one. In-flight @call@ TMVars are aborted on
-- disconnect so callers don't hang.
module Max.Deps
  ( AppDeps (..),
  )
where

import Control.Concurrent.STM (TVar)
import Max.DB.Connection (DbPool)
import Max.Forward (ForwardQueue)
import Max.Images (ImageQueue)
import OneBot.Server (Client)

data AppDeps = AppDeps
  { db :: !DbPool,
    imageQ :: !ImageQueue,
    forwardQ :: !ForwardQueue,
    -- | Published by 'OneBot.Server' on connect / cleared on disconnect.
    -- Workers that need to issue actions read this to find the live client.
    clientRef :: !(TVar (Maybe Client))
  }
