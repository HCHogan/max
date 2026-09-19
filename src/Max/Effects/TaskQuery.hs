{-# LANGUAGE TypeFamilies #-}

-- | Read jobs in the bound conversation without exposing their runtime.
module Max.Effects.TaskQuery (TaskQuery, listTasks, readTask, runTaskQuery) where

import Data.Int (Int64)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Max.Jobs qualified as Jobs
import Max.Task.Types (JobView)
import OneBot.Types (GroupId)

data TaskQuery :: Effect where
  ListTasks :: TaskQuery m [JobView]
  ReadTask :: Int64 -> TaskQuery m (Maybe JobView)

type instance DispatchOf TaskQuery = Dynamic

listTasks :: (TaskQuery :> es) => Eff es [JobView]
listTasks = send ListTasks

readTask :: (TaskQuery :> es) => Int64 -> Eff es (Maybe JobView)
readTask = send . ReadTask

runTaskQuery :: (IOE :> es) => Jobs.Jobs -> GroupId -> Eff (TaskQuery : es) a -> Eff es a
runTaskQuery jobs group = interpret $ \_ -> \case
  ListTasks -> liftIO (Jobs.listJobs jobs group)
  ReadTask identifier -> liftIO (Jobs.lookupJob jobs group identifier)
