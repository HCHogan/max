module Max.LLM.Admission (Priority (..), Admission, newAdmission, withAdmission, admissionCounts, priorityForSource) where

import Control.Concurrent.STM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import Effectful
import Effectful.Exception (bracket)

data Priority = Interactive | Background deriving stock (Eq, Show)

data Pool = Pool
  { waiting :: !(Map Integer Priority),
    running :: !(Map Integer Priority),
    interactiveBurst :: !Int
  }

data Admission = Admission
  { pools :: !(TVar (Map Text Pool)),
    sequenceNumber :: !(TVar Integer),
    capacity :: !Int,
    reserved :: !Int
  }

newAdmission :: Int -> Int -> IO Admission
newAdmission capacity reserved
  | capacity < 1 || reserved < 0 || reserved >= capacity = ioError (userError "invalid model admission capacity")
  | otherwise = Admission <$> newTVarIO Map.empty <*> newTVarIO 0 <*> pure capacity <*> pure reserved

priorityForSource :: Text -> Priority
priorityForSource source
  | source `elem` ["turn", "wrapup", "request", "task-summary"] = Interactive
  | otherwise = Background

withAdmission :: (IOE :> es) => Admission -> Text -> Priority -> Eff es value -> Eff es value
withAdmission admission provider priority action =
  bracket (liftIO (atomically enqueue)) (liftIO . atomically . release) $ \ticket -> do
    liftIO (atomically (acquire ticket))
    action
  where
    emptyPool = Pool Map.empty Map.empty 0
    enqueue = do
      ticket <- readTVar admission.sequenceNumber
      modifyTVar' admission.sequenceNumber (+ 1)
      modifyTVar' admission.pools $
        Map.alter
          (Just . (\pool -> pool {waiting = Map.insert ticket priority pool.waiting}) . fromMaybe emptyPool)
          provider
      pure ticket
    acquire ticket = do
      state <- readTVar admission.pools
      let pool = Map.findWithDefault emptyPool provider state
          first requested = fst <$> Map.lookupMin (Map.filter (== requested) pool.waiting)
          backgroundCount = Map.size (Map.filter (== Background) pool.running)
          backgroundReady = isJust (first Background) && backgroundCount < admission.capacity - admission.reserved
          permitted = case priority of
            Interactive -> not backgroundReady || pool.interactiveBurst < 5
            Background ->
              backgroundCount < admission.capacity - admission.reserved
                && (isNothing (first Interactive) || pool.interactiveBurst >= 5)
      check (Map.size pool.running < admission.capacity && first priority == Just ticket && permitted)
      let updated =
            pool
              { waiting = Map.delete ticket pool.waiting,
                running = Map.insert ticket priority pool.running,
                interactiveBurst = if priority == Interactive then min 5 (pool.interactiveBurst + 1) else 0
              }
      writeTVar admission.pools (Map.insert provider updated state)
    release ticket =
      modifyTVar' admission.pools $
        Map.update
          ( \pool ->
              let updated = pool {waiting = Map.delete ticket pool.waiting, running = Map.delete ticket pool.running}
               in if Map.null updated.waiting && Map.null updated.running then Nothing else Just updated
          )
          provider

admissionCounts :: Admission -> Text -> IO (Int, Int)
admissionCounts admission provider = atomically $ do
  state <- readTVar admission.pools
  pure $ case Map.lookup provider state of
    Nothing -> (0, 0)
    Just pool -> (Map.size pool.running, Map.size pool.waiting)
