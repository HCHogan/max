{-# LANGUAGE TypeFamilies #-}

-- | Read task facts within one conversation. Callers cannot choose another
-- scope and never receive a database connection.
module Max.Effects.TaskQuery (TaskQuery, listTasks, readTask, runTaskQuery) where

import Data.Int (Int64)
import Effectful
import Effectful.Dispatch.Dynamic (interpret, send)
import Effectful.PostgreSQL (WithConnection)
import Max.DB.Task.Query qualified as DB
import Max.Task.Query (TaskDetails, TaskSummary)
import OneBot.Types (GroupId)

data TaskQuery :: Effect where
  ListTasks :: TaskQuery m [TaskSummary]
  ReadTask :: Int64 -> TaskQuery m (Maybe TaskDetails)

type instance DispatchOf TaskQuery = Dynamic

listTasks :: (TaskQuery :> es) => Eff es [TaskSummary]
listTasks = send ListTasks

readTask :: (TaskQuery :> es) => Int64 -> Eff es (Maybe TaskDetails)
readTask = send . ReadTask

runTaskQuery :: (WithConnection :> es, IOE :> es) => GroupId -> Eff (TaskQuery : es) a -> Eff es a
runTaskQuery group = interpret $ \_ -> \case
  ListTasks -> DB.listTasks group
  ReadTask identifier -> DB.readTask group identifier
