{-# language LambdaCase, TupleSections #-}
module HFish.Interpreter.Util where

import Data.Bifunctor
import Text.Read
import qualified Data.Text as T
import Data.Foldable (foldr1)
import Data.Monoid
import Control.Monad.IO.Class


mintcal :: Monoid m => m -> [m] -> m
mintcal m = \case
  [] -> mempty
  ms -> foldr1 (\x y -> x <> m <> y) ms

infixl 4 <$$>
(<$$>) :: Functor f => f a -> (a -> b) -> f b
(<$$>) = flip (<$>)
-- ^ A flipped version of (<$>)

whenJust :: Applicative f
  => Maybe a -> (a -> f ()) -> f ()
whenJust = flip $ maybe (pure ())

onMaybe :: Maybe a -> b -> (a -> b) -> b
onMaybe ma b f = maybe b f ma

splitAtMaybe :: Int -> [a] -> Maybe ([a],[a])
splitAtMaybe i
  | i < 0 = const Nothing
  | i == 0 = Just . ([],)
  | otherwise = \case
    [] -> Nothing
    x:xs -> first (x:)
      <$> splitAtMaybe (i-1) xs

readText :: Read a => T.Text -> a
readText = read . T.unpack

readTextMaybe :: Read a => T.Text -> Maybe a
readTextMaybe = readMaybe . T.unpack

readTextsMaybe :: Read a => [T.Text] -> Maybe a
readTextsMaybe = readTextMaybe . T.unwords

showText :: Show a => a -> T.Text
showText = T.pack . show


showCall :: (MonadIO m,Show a) => String -> [a] -> m ()
showCall f args =
  ( liftIO . putStrLn )
    ( f <> " " <> mintcal " " (map show args) )
