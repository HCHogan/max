module Main (main) where

import Control.Concurrent.STM (STM, TVar, atomically, newTVar, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Monad (forever, when)
import Control.Monad.Cont
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.Monoid
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Network.WebSockets qualified as WS

main :: IO ()
main = do
  let port = 8000 :: Int
  putStrLn $ "listening on:" <> show port
  WS.runServer "127.0.0.1" port application

application :: WS.ServerApp
application pending = do
  conn <- WS.acceptRequest pending
  TIO.putStrLn "new client connected!"

  WS.withPingThread conn 30 (return ()) $ do
    forever $ do
      msg <- WS.receiveData conn :: IO Text
      TIO.putStrLn $ "received: " <> msg
      WS.sendTextData conn $ "echo: " <> msg

type Account = TVar Int

transfer :: Account -> Account -> Int -> STM ()
transfer from to amount = do
  v1 <- readTVar from
  v2 <- readTVar to
  writeTVar from (v1 - amount)
  writeTVar to (v2 + amount)

-- >>> do { acc1 <- newTVarIO 100; acc2 <- newTVarIO 0; atomically $ transfer acc1 acc2 10; readTVarIO acc2 }
-- 10

myLast :: [a] -> Maybe a
myLast [] = Nothing
myLast [x] = Just x
myLast (_ : xs) = myLast xs

-- >>> myLast [1,2,3,4]
-- Just 4

myButLast :: [a] -> Maybe a
myButLast [] = Nothing
myButLast [_] = Nothing
myButLast [x, _] = Just x
myButLast (_ : xs) = myButLast xs

-- >>> myButLast [1, 2, 3]
-- Just 2

elementAt :: [a] -> Int -> Maybe a
elementAt (x : _) 0 = Just x
elementAt [_] n | n > 0 = Nothing
elementAt [] _ = Nothing
elementAt (_ : xs) n = elementAt xs (n - 1)

-- >>> elementAt [1,2,3] 2
-- Just 3

myLength :: [Int] -> Int
myLength = getSum . foldMap (const (Sum 1))

-- >>> myLength [1,2,3]
-- 3

myReverse :: [a] -> [a]
myReverse [] = []
myReverse [x] = [x]
myReverse (x : xs) = myReverse xs ++ [x]

-- >>> myReverse [1,2,3]
-- [3,2,1]

ap :: (Monad m) => m (a -> b) -> m a -> m b
ap mab ma = mab >>= (<$> ma)

liftA5 :: (Applicative f) => (a -> b -> c -> d -> e -> k) -> f a -> f b -> f c -> f d -> f e -> f k
liftA5 f fa fb fc fd fe = f <$> fa <*> fb <*> fc <*> fd <*> fe

-- >>> [(2*), (5*), (9*)] <*> [1,4,7]
-- [2,8,14,5,20,35,9,36,63]

-- >>> zipWith ($) [(2*), (5*), (9*)] [1,4,7]
-- [2,20,63]

newtype ZipList a = ZipList {getZipList :: [a]}

instance Functor ZipList where
  fmap f (ZipList xs) = ZipList (f <$> xs)

instance Applicative ZipList where
  (ZipList fs) <*> (ZipList xs) = ZipList (zipWith ($) fs xs)
  pure x = ZipList $ repeat x

newtype MaybeIO a = MaybeIO {runMaybeIO :: IO (Maybe a)}

instance Functor MaybeIO where
  fmap f (MaybeIO ima) = MaybeIO $ (f <$>) <$> ima

instance Applicative MaybeIO where
  pure a = MaybeIO $ pure $ pure a
  (MaybeIO imf) <*> (MaybeIO ima) = MaybeIO $ liftA2 (<*>) imf ima

instance Monad MaybeIO where
  MaybeIO m >>= f = MaybeIO $ do
    ma <- m
    case ma of
      Nothing -> return Nothing
      Just a -> let MaybeIO b = f a in b

newtype MyMaybeT m a = MaybeT {runMaybeT :: m (Maybe a)}

instance (Functor m) => Functor (MyMaybeT m) where
  fmap f (MaybeT mma) = MaybeT $ (f <$>) <$> mma

instance (Applicative m) => Applicative (MyMaybeT m) where
  pure a = MaybeT $ pure $ Just a
  (MaybeT mmf) <*> (MaybeT mma) = MaybeT $ liftA2 (<*>) mmf mma

instance (Monad m) => Monad (MyMaybeT m) where
  (MaybeT mma) >>= f = MaybeT $ do
    ma <- mma
    case ma of
      Nothing -> return Nothing
      Just a -> let (MaybeT mmb) = f a in mmb

-- | 读法：MaybeT 给任意 Monad m 添加了"可能失败"的语义
-- | MaybeT IO 现在是个 Monad，但你写 do 时会立刻撞墙：
-- > prog :: MaybeT IO ()
-- > prog = putStrLn "fuck" -- 类型错误！putStrLn :: IO ()，不是 MaybeT IO ()
-- 需要一个把底层操作抬升的工具
class MyMonadTrans t where
  lift :: (Monad m) => m a -> t m a

instance MyMonadTrans MyMaybeT where
  lift m = MaybeT $ fmap Just m

-- | 于是:
-- > prog :: MaybeT IO ()
-- > prog = lift $ putStrLn "fuck"
data Config

data AppState
  deriving (Show)

data AppError

type App = ReaderT Config (StateT AppState (ExceptT AppError IO))

runApp :: App a -> Config -> AppState -> IO (Either AppError (a, AppState))
runApp app cfg s = runExceptT $ runStateT (runReaderT app cfg) s

doStuff :: (MonadReader Config m, MonadState AppState m, MonadIO m) => m ()
doStuff = do
  _cfg <- ask
  s <- get
  liftIO $ print s

addCPS :: Int -> Int -> (Int -> r) -> r
addCPS a b k = k (a + b)

squareCPS :: Int -> (Int -> r) -> r
squareCPS a k = k (a * a)

newtype MyCont r a = MyCont {runMyCont :: (a -> r) -> r}

instance Functor (MyCont r) where
  fmap f (MyCont c) = MyCont $ \k -> c (k . f)

instance Applicative (MyCont r) where
  pure a = MyCont $ \k -> k a
  (MyCont abrr) <*> (MyCont arr) = MyCont $ \k -> abrr $ \ab -> arr $ \a -> k $ ab a

instance Monad (MyCont r) where
  (MyCont arr) >>= fabrr = MyCont $ \k -> arr $ \a -> runMyCont (fabrr a) $ \b -> k b

myCallCC :: ((a -> MyCont r b) -> MyCont r a) -> MyCont r a
myCallCC f = MyCont $ \k -> runMyCont (f (\a -> MyCont $ \_ -> k a)) $ \a -> k a

example :: Int -> MyCont r Int
example n = myCallCC $ \exit -> do
  when (n < 0) $ exit 0
  let r = n * 2
  when (r > 100) $ exit 100
  return r

-- >>> runCont (example -1) id
