{-# language LambdaCase, GADTs, OverloadedStrings, TupleSections #-}
module HFish.Interpreter.Builtins.Seq (
  seqF
) where

import HFish.Lang.Lang
import HFish.Interpreter.Core
import HFish.Interpreter.IO
import HFish.Interpreter.Concurrent
import HFish.Interpreter.Status
import HFish.Interpreter.Util

import Control.Lens
import Control.Monad.IO.Class
import Control.Concurrent
import qualified Data.Text.IO as TextIO
import qualified Data.Text as T
import Text.Read
import Data.Functor
import System.Exit
import System.IO

seqF :: Bool -> [T.Text] -> Fish ()
seqF fork = \case
  [] -> errork "seq: too few arguments given"
  [l] -> seqFWorker fork ((1,1,) <$> mread l)
  [f,l] -> seqFWorker fork ((,1,) <$> mread f <*> mread l)
  [f,i,l] -> seqFWorker fork ((,,) <$> mread f <*> mread i <*> mread l)
  _ -> errork "seq: too many arguments given"
  where
    mread = readTextMaybe

seqFWorker :: Bool -> Maybe (Int,Int,Int) -> Fish ()
seqFWorker fork = \case
    Nothing -> errork "seq: invalid argument(s) given"
    Just (a,b,c) -> do
      if fork
        then forkFish (writeList a b c) >> ok
        else writeList a b c >> ok

writeList :: Int -> Int -> Int -> Fish ()
writeList a b c = (echo . T.unlines) $ createList a b c

createList :: Int -> Int -> Int -> [T.Text]
createList a b c
  | a <= c = T.pack (show a) : createList (a+b) b c
  | otherwise = []