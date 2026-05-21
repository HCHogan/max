{-# LANGUAGE OrPatterns #-}

module Max.Misc () where

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

