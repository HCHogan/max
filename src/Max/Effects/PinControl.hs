{-# LANGUAGE TypeFamilies #-}

-- | Only pin edits, bound to the current turn and conversation. Session model,
-- persona and general configuration mutation are not part of this capability.
module Max.Effects.PinControl (PinControl, PinControlScope (..), pinMessage, unpinMessage, runPinControl) where

import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.Log (Log, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.History (fetchMessageInScope)
import Max.DB.Task.Authorization (authorizeCallerWithin)
import Max.Pin.Policy
import Max.Platform.Types (PrincipalId)
import Max.Session (Session (..), SessionRegistry, loadSession, updateSessionGuarded)
import Max.Turn.Types (AgentTurnId)
import OneBot.Types (GroupId)

data PinControlScope = PinControlScope
  { group :: !GroupId,
    turn :: !(Maybe AgentTurnId),
    principal :: !PrincipalId
  }

data PinControl :: Effect where
  PinMessage :: Int64 -> PinControl m (Either PinFailure Int)
  UnpinMessage :: Int64 -> PinControl m (Either PinFailure Int)

type instance DispatchOf PinControl = Dynamic

pinMessage :: (PinControl :> es) => Int64 -> Eff es (Either PinFailure Int)
pinMessage = send . PinMessage

unpinMessage :: (PinControl :> es) => Int64 -> Eff es (Either PinFailure Int)
unpinMessage = send . UnpinMessage

runPinControl :: forall es a. (WithConnection :> es, Log :> es, IOE :> es) => PinControlScope -> SessionRegistry -> Text -> Eff (PinControl : es) a -> Eff es a
runPinControl scope sessions defaultModel = interpret $ \_ -> \case
  PinMessage message -> submit "pin" True message addToolPin
  UnpinMessage message -> submit "unpin" False message removeToolPin
  where
    submit :: Text -> Bool -> Int64 -> (Int64 -> [Int64] -> Either PinFailure [Int64]) -> Eff es (Either PinFailure Int)
    submit operation checkVisible message decide = do
      result <- case scope.turn of
        Nothing -> pure (Left PinCallerFenced)
        Just turn -> do
          session <- loadSession sessions defaultModel scope.group
          let guard = do
                authorized <- authorizeCallerWithin turn scope.group scope.principal
                if not authorized
                  then pure (Left PinCallerFenced)
                  else do
                    visible <- if checkVisible then isJust <$> fetchMessageInScope (conversationScopeFor scope.group) message else pure True
                    pure (if visible then Right () else Left PinNotVisible)
          updateSessionGuarded session guard $ \current -> do
            pins <- decide message current.pinned
            pure (current {pinned = pins}, length pins)
      forM_ result $ \count -> logInfo "pin tool: mutation" (object ["operation" .= operation, "message_id" .= message, "pin_count" .= count])
      pure result
