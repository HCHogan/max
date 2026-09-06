-- | Bounded, generation-fenced QQ history reads. Raw OneBot actions and
-- response envelopes do not escape this adapter into conversation handling.
module Max.Platform.QQHistory (QQHistoryPage (..), readQQHistoryPage, qqGenerationIsCurrent) where

import Control.Concurrent.STM (TVar)
import Data.Text qualified as T
import Max.Platform.Failure (PlatformFailure)
import Max.Platform.Rpc (callQQActionOnGeneration, qqGenerationIsCurrent)
import OneBot.Action (Action (GetFriendMsgHistory, GetGroupMsgHistory), Response (..))
import OneBot.Event (HistoricalMessage, HistoryParseFailure, parseHistoryMessages)
import OneBot.Server (ClientSlot)
import OneBot.Types (GroupId, UserId, isPrivateChat, privateChatUserId)

data QQHistoryPage = QQHistoryPage
  { qhpSucceeded :: !Bool,
    qhpMessages :: ![HistoricalMessage],
    qhpParseFailures :: !Int,
    qhpParseFailureDetails :: ![HistoryParseFailure],
    qhpErrors :: ![T.Text]
  }

readQQHistoryPage :: TVar ClientSlot -> Int -> UserId -> GroupId -> Maybe T.Text -> Int -> Int -> IO (Either PlatformFailure QQHistoryPage)
readQQHistoryPage client generation self group anchor limit timeoutMs =
  fmap (observeHistoryPage self group) <$> callQQActionOnGeneration client generation action timeoutMs
  where
    action
      | isPrivateChat group = GetFriendMsgHistory (privateChatUserId group) anchor limit
      | otherwise = GetGroupMsgHistory group anchor limit

observeHistoryPage :: UserId -> GroupId -> Response -> QQHistoryPage
observeHistoryPage self group response
  | response.retcode /= 0 =
      QQHistoryPage
        False
        []
        0
        []
        ["NapCat history retcode=" <> T.pack (show response.retcode) <> " status=" <> response.status]
  | otherwise = case parseHistoryMessages self group response.payload of
      Left err -> QQHistoryPage False [] 1 [] ["history payload parse failed: " <> T.pack err]
      Right (messages, failures) -> QQHistoryPage True messages (length failures) failures []
