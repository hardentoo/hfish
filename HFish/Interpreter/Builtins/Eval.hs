module HFish.Interpreter.Builtins.Eval (
  evalF
  ,execF
  -- ,callF
) where

import HFish.Interpreter.Parsing
import HFish.Interpreter.Core
import HFish.Interpreter.Interpreter (progA)
import qualified Data.Text as T
import Fish.Lang
import System.Posix.Process
import System.Exit
import Control.Lens
import Control.Monad
import Control.Monad.IO.Class

onArgs :: [T.Text] -> (Prog () -> Fish a) -> Fish (Maybe a)
onArgs ts k = do
  res <- parseFishInteractive $ (T.unpack . T.unwords) ts
  withProg res k

evalF :: Builtin
evalF _ ts = void (onArgs ts progA)

execF :: Builtin
execF _ ts = 
  map T.unpack ts & \(name:args) ->
   liftIO $ executeFile name True args Nothing

