{-# LANGUAGE OrPatterns #-}

module Max.Misc where

import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Data.Monoid

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


