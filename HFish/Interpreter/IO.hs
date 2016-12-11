{-# LANGUAGE LambdaCase, OverloadedStrings, PackageImports #-}
module HFish.Interpreter.IO (
  duplicate
  ,withFileR
  ,withFileW
  ,readFrom
  ,readLineFrom
  ,writeTo
  ,echo
  ,echoLn
  ,warn
) where

import HFish.Interpreter.Util
import HFish.Interpreter.FdTable
import HFish.Interpreter.Core
import HFish.Interpreter.Status
import HFish.Interpreter.Posix.IO
import qualified HFish.Lang.Lang as L

import Control.Monad
import Control.Applicative
import Control.Monad.IO.Class
import qualified Control.Exception as E
import Data.Monoid
import Data.Bool
import System.IO
import System.IO.Error as IOE
import System.Posix.Files
import qualified System.Posix.Types as PT
import qualified System.Posix.IO as P
import qualified Data.Text as T
import qualified Data.Text.IO as TextIO



-- | Make an abstract fd a duplicate of another abstract fd, i.e. a fd pointing
--
--   to the same OS fd as the other (it mimics the dup2 syscall on Posix systems).
-- 
--   This may fail if the second fd is invalid.
--
duplicate :: L.Fd -- ^ file descriptor to duplicate
  -> L.Fd -- ^ \"new\" file descriptor, which shall point to the
          --   same OS fd as the first after the call.
  -> Fish a -> Fish a
duplicate fd1 fd2 k = do
  pfd <- lookupFd' fd1
  insert fd2 pfd k

withFileR :: T.Text -> L.Fd -> Fish () -> Fish ()
withFileR fpath fd k = do
  pfd <- liftIO $ P.openFd
    (T.unpack fpath)
    P.ReadOnly
    Nothing
    P.defaultFileFlags
  insert fd pfd
    ( k `finally` P.closeFd pfd )


withFileW :: T.Text -> L.FileMode -> L.Fd -> Fish () -> Fish ()
withFileW fpath mode fd k =
  let popen m f = P.openFd (T.unpack fpath) P.WriteOnly m f
   in do
    mpfd <- treatExceptions $ case mode of
      L.FModeWrite -> popen (Just accessMode)
        P.defaultFileFlags { P.trunc = True }
      L.FModeApp -> popen (Just accessMode)
        P.defaultFileFlags { P.append = True }
      L.FModeNoClob -> popen (Just accessMode)
        P.defaultFileFlags { P.exclusive = True }
    case mpfd of
      Just pfd -> insert fd pfd
        ( k `finally` P.closeFd pfd )
      Nothing -> return ()
  where
    accessMode = 
      foldr unionFileModes nullFileMode
      [ ownerReadMode, ownerWriteMode, groupReadMode, otherReadMode ]
    
    treatExceptions :: IO PT.Fd -> Fish (Maybe PT.Fd)
    treatExceptions f =  liftIO
      ( E.tryJust 
        ( bool Nothing (Just ()) . IOE.isAlreadyExistsError ) f )
      >>= \case
        Right pfd -> return (Just pfd)
        Left () -> do
          writeTo L.Fd2
            $ "File \"" <> fpath <> "\" aready exists.\n"
          bad
          return Nothing
    
    {-
    mkErr err = errork
      $ "failed to open file "
      <> fpath <> " due to: "
      <> showText err -}

readFrom :: FdData a => L.Fd -> Fish a
readFrom fd = do
  pfd <- lookupFd' fd
  liftIO $ fdGetContents pfd

readLineFrom :: FdData a => L.Fd -> Fish a
readLineFrom fd = do
  pfd <- lookupFd' fd
  liftIO $ fdGetLine pfd  

writeTo :: FdData a => L.Fd -> a -> Fish ()
writeTo fd text = do
  pfd <- lookupFd' fd
  liftIO $ fdPut pfd text

echo :: T.Text -> Fish ()
echo = writeTo L.Fd1

echoLn :: T.Text -> Fish ()
echoLn t = echo (t <> "\n")

-- | 'warn' bypasses the whole Fd passing machinery
--
--   and writes directly to stderr. Use for debugging only.
warn :: T.Text -> Fish ()
warn t = liftIO (TextIO.hPutStrLn stderr t)

lookupFd' :: L.Fd -> Fish PT.Fd
lookupFd' fd = lookupFd fd >>=
  maybe (notOpenErr fd) return

-- Errors:

mkFdErr :: T.Text -> L.Fd -> Fish a
mkFdErr t fd = errork
  $ "file descriptor " <> (showText . fromEnum) fd <> " is " <> t

invalidFdErr = mkFdErr "invalid"
notOpenErr = mkFdErr "not open"
notReadableErr = mkFdErr "not readable"
notWriteableErr = mkFdErr "not writeable"
      
