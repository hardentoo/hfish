{-# language LambdaCase, OverloadedStrings #-} module
HFish.Interpreter.Interpreter where

import Fish.Lang hiding (Scope)
import qualified Fish.Lang as L

import HFish.Interpreter.Scope
import HFish.Interpreter.Core
import HFish.Interpreter.FdTable as FDT
import HFish.Interpreter.IO
import HFish.Interpreter.Status
import HFish.Interpreter.Var
import HFish.Interpreter.Cwd
import HFish.Interpreter.Globbed
import HFish.Interpreter.Process.Process
import HFish.Interpreter.Process.Pid
import HFish.Interpreter.Concurrent
import HFish.Interpreter.Slice
import HFish.Interpreter.Util
import HFish.Interpreter.ExMode
import HFish.Interpreter.Env as Env
import qualified HFish.Interpreter.SetCmd as SetCmd
import qualified HFish.Interpreter.FuncSt as FuncSt

import Data.NText
import Data.Monoid
import Data.Maybe
import Data.Bool
import qualified Data.List.NonEmpty as N
import qualified Data.Text as T
import Control.Lens
import Control.Monad
import Control.Monad.State
import Control.Applicative
import Control.Concurrent
import Control.Concurrent.MVar
import qualified System.Posix.IO as PIO


progA :: Prog T.Text t -> Fish ()
progA (Prog _ cstmts) = forM_ cstmts compStmtA

compStmtA :: CompStmt T.Text t -> Fish ()
compStmtA = \case
  Simple _ st -> simpleStmtA st
  Piped _ d st cst -> pipedStmtA d st cst
  Forked _ st -> stmtA ForkedExM st

simpleStmtA :: Stmt T.Text t -> Fish ()
simpleStmtA = stmtA InOrderExM

pipedStmtA :: Fd -> Stmt T.Text t -> CompStmt T.Text t -> Fish ()
pipedStmtA fd st cst = 
  pipeFish fd (stmtA PipeExM st) (compStmtA cst)

stmtA :: ExMode -> Stmt T.Text t -> Fish ()
stmtA mode = \case
  CmdSt _ i args ->
    cmdStA mode i args
  SetSt _ setCmd -> 
    setStA setCmd
  FunctionSt _ i args prog ->
    functionStA i args prog
  WhileSt _ st prog ->
    whileStA st prog
  ForSt _ i args prog ->
    forStA i args prog
  IfSt _ branches elBranch ->
    ifStA (N.toList branches) elBranch
  SwitchSt _ e branches -> 
    switchStA e (N.toList branches)
  BeginSt _ prog -> 
    beginStA prog
  AndSt _ st ->
    andStA st
  OrSt _ st ->
    orStA st
  NotSt _ st ->
    notStA st
  RedirectedSt _ st redirects ->
    redirectedStmtA (stmtA mode st) (N.toList redirects)
  CommentSt _ _ -> return ()

cmdStA :: ExMode -> CmdIdent T.Text t -> Args T.Text t -> Fish ()
cmdStA mode (CmdIdent _ ident) args = do
  ts <- evalArgs args
  bn <- views builtins (`Env.lookup` ident)
  fn <- uses functions (`Env.lookup` ident)
  case (bn,fn) of
    (Just b,_) -> b (isFork mode) ts
    (_,Just f) -> setReturnK $ f ts
    (Nothing,Nothing) -> do
      pid <- fishCreateProcess identText ts
      if isInOrder mode
        then fishWaitForProcess identText pid
        else return ()
  where
    identText = extractText ident

setStA :: SetCommand T.Text t -> Fish ()
setStA = SetCmd.setCommandA evalArgs evalRef

functionStA :: FunIdent T.Text t -> Args T.Text t -> Prog T.Text t -> Fish ()
functionStA ident args prog = evalArgs args
  >>= \ts -> FuncSt.funcStA progA ident ts prog


whileStA :: Stmt T.Text t -> Prog T.Text t -> Fish ()
whileStA st prog = setBreakK loop
  where
    body = progA prog
    loop = do
      simpleStmtA st
      ifOk ( setContinueK body
             >> loop )

forStA :: VarIdent T.Text t -> Args T.Text t -> Prog T.Text t -> Fish ()
forStA (VarIdent _ varIdent) args prog = do
  xs <- evalArgs args
  setBreakK (loop xs)
  where
    lbind x f = localise localEnv
      (setVarSafe LocalScope varIdent (mkVar [x]) >> f)
    
    body = progA prog
    
    loop [] = return ()
    loop (x:xs) = do
      lbind x $ setContinueK body
      loop xs

ifStA :: [(Stmt T.Text t,Prog T.Text t)] -> Maybe (Prog T.Text t) -> Fish ()
ifStA [] (Just prog) = progA prog
ifStA [] Nothing = return ()
ifStA ((st,prog):blks) elblk = do
  simpleStmtA st
  onStatus
    (const $ ifStA blks elblk)
    (progA prog >> ok)

switchStA :: Expr T.Text t -> [(Expr T.Text t,Prog T.Text t)] -> Fish ()
switchStA e brnchs = view fishCompatible >>=
  bool (hfishSwitch e brnchs) (fishSwitch e brnchs)

-- | Match a string against a number of glob patterns.
--
--   This implementation deviates strongly from the original fish:
--
--   If given an array instead of a string, it will match against
--   the arrays serialisation.
--
--   Arguments to the /case/ branches are serialised as well
--   and then interpreted as glob patterns.
--
--   These glob patterns are matched directly against the string,
--   superseding the usual glob pattern expansion.
--
--   The matching is lazy and does not fall through, i.e.
--   when a branch is taken all branches following it
-- 
--   will not be evaluated. This seems to agree with the fish impl.
hfishSwitch ::  Expr T.Text t -> [(Expr T.Text t,Prog T.Text t)] -> Fish ()
hfishSwitch e branches = do
  text <- T.unwords <$> evalArg e
  loop text branches
  where
    loop _ [] = return ()
    loop text ((e,prog):branches) = do
      glob <- mintcal " " <$> evalExpr e
      matchGlobbed glob text & \case
        Just _ -> progA prog
        Nothing -> loop text branches

fishSwitch :: Expr T.Text t -> [(Expr T.Text t,Prog T.Text t)] -> Fish ()
fishSwitch e branches = evalArg e >>= \case
  [text] -> loop text branches
  _ -> tooManyErr
  where
    loop _ [] = return ()
    loop text ((e,prog):branches) = do
      globText <- mintcal " " <$> evalArg e
      matchText globText text & \case
        Just _ -> progA prog
        Nothing -> loop text branches
    
    tooManyErr = errork
      $ "switch: too many arguments given"

beginStA :: Prog T.Text t -> Fish ()
beginStA prog =
  localise localEnv
  $ progA prog

andStA :: Stmt T.Text t -> Fish ()
andStA st = ifOk $ simpleStmtA st
  
orStA :: Stmt T.Text t -> Fish ()
orStA st = unlessOk $ simpleStmtA st

notStA :: Stmt T.Text t -> Fish ()
notStA st = 
  simpleStmtA st >> invertStatus

redirectedStmtA :: Fish () -> [Redirect T.Text t] -> Fish ()
redirectedStmtA f redirects = void (setupAll f)
  where
    setupAll = foldr ((.) . setup) id redirects

    setup red f = red & \case
      RedirectClose fd -> close fd f
      RedirectIn fd t -> t & \case
        Left fd2 -> duplicate fd2 fd f
        Right e -> do
          name <- evalArg e >>= checkSingleton
          withFileR name fd f
      RedirectOut fd t -> t & \case
        Left fd2 -> duplicate fd2 fd f
        Right (mode,e) -> do
          name <- evalArg e >>= checkSingleton
          withFileW name mode fd f
    
    checkSingleton :: [a] -> Fish a
    checkSingleton = \case
      [] -> errork "missing file name in redirection"
      [x] -> return x
      _ -> errork "more then one file name in redirection"

{- Expression evaluation -}
evalArgs :: Args T.Text t -> Fish [T.Text]
evalArgs (Args _ es) = join <$> forM es evalArg

evalArg :: Expr T.Text t -> Fish [T.Text]
evalArg arg = do
  globs <- evalExpr arg
  vs <- forM globs globExpand
  return (join vs)

evalExpr :: Expr T.Text t -> Fish [Globbed]
evalExpr = \case
  GlobE _ g -> return [Globbed [Left g]]
  ProcE _ e -> evalProcE e
  HomeDirE _ -> evalHomeDirE
  StringE _ t -> return [fromText t]
  VarRefE _ q vref -> evalVarRefE q vref
  BracesE _ es -> evalBracesE es
  CmdSubstE _ cmdref -> evalCmdSubstE cmdref
  ConcatE _ e1 e2 -> evalConcatE e1 e2

evalProcE :: Expr T.Text t -> Fish [Globbed]
evalProcE e = 
  evalArg e >>= (getPID . T.intercalate "")

evalHomeDirE :: Fish [Globbed]
evalHomeDirE = do
  home <- getHOME
  return [fromString home]

evalBracesE :: [Expr T.Text t] -> Fish [Globbed]
evalBracesE es = 
  join <$> forM es evalExpr

evalCmdSubstE :: CmdRef T.Text t -> Fish [Globbed]
evalCmdSubstE (CmdRef _ prog ref) = do
  (mvar,wE) <- createHandleMVarPair
  FDT.insert Fd1 wE (progA prog) `finally` PIO.closeFd wE
  text <- liftIO $ takeMVar mvar
  T.lines text & \ts ->
    map fromText <$> case ref of
      Nothing -> return ts
      Just _ -> do
        let l = length ts
        indices <- evalRef ref
        readIndices indices (Var UnExport l ts)

evalVarRefE :: Bool -> VarRef T.Text t -> Fish [Globbed]
evalVarRefE s vref = do
  vs <- evalVarRef vref
  return $ map fromText (ser vs)
  where
    ser = if s then pure . T.unwords else id

evalVarRef :: VarRef T.Text t -> Fish [T.Text]
evalVarRef (VarRef _ name ref) = do
  varIdents <- evalName name
  vs <- forM varIdents lookupVar
  return (join vs)
  where
    lookupVar ident = do
      var@(Var _ _ ts) <- getVar ident
      if isNothing ref
        then return ts
        else do
          indices <- evalRef ref
          readIndices indices var
    
    evalName = \case
      Left vref -> map mkNText <$> evalVarRef vref
      Right (VarIdent _ i) -> return [i]
    

evalRef :: Ref (Expr T.Text t) -> Fish [(Int,Int)]
evalRef ref =
  join <$> forM (onMaybe ref [] id) indices
  where
    indices = \case
      Index a -> (\xs -> zip xs xs) <$> evalInt a
      Range a b -> liftA2 (,) <$> evalInt a <*> evalInt b  
  
evalConcatE :: Expr T.Text t -> Expr T.Text t -> Fish [Globbed]
evalConcatE e1 e2 = do
  gs1 <- evalExpr e1
  gs2 <- evalExpr e2
  return $ map Globbed (cartesian (map unGlob gs1) (map unGlob gs2))
  where
    cartesian = liftA2 (<>)

{- Try to interpret Expression as an Int -}

evalInt :: Expr T.Text t -> Fish [Int]
evalInt e = do
  vs <- evalArg e
  forM (T.words =<< vs) f
  where
    f v = case readTextMaybe v of
      Just x -> return x
      Nothing -> errork
        $ "failed to interpret expression "
          <> "as integer: " <> v

    
