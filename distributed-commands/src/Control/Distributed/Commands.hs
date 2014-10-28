{-# LANGUAGE LambdaCase #-}
module Control.Distributed.Commands where

import Control.Concurrent (forkIO)
import Control.Exception (throwIO, evaluate)
import Control.Monad (void)
import Data.IORef (atomicModifyIORef', newIORef)
import System.Exit (ExitCode(..))
import System.IO (hGetContents, IOMode(..), withFile, hSetBuffering, BufferMode(..))
import System.Process
    ( StdStream(..)
    , proc
    , createProcess
    , CreateProcess(..)
    , waitForProcess
    )


-- | 'scp' paths are either local or remote.
data ScpPath = LocalPath FilePath
             | -- | @RemotePath (Just user) host path@
               RemotePath (Maybe String) String FilePath

-- | @scp src dst@
--
-- Copies files with scp.
--
scp :: ScpPath -> ScpPath -> IO ()
scp src dst =
    withFile "/dev/null" ReadWriteMode $ \dev_null -> do
      (_, _, _, ph) <- createProcess
        (proc "scp" [ "-r"
                    , "-o", "UserKnownHostsFile=/dev/null"
                    , "-o", "StrictHostKeyChecking=no"
                    , showPath src
                    , showPath dst
                    ])
        { std_in  = UseHandle dev_null
        , std_out = UseHandle dev_null
        , std_err = UseHandle dev_null
        }
      ret <- waitForProcess ph
      case ret of
        ExitSuccess -> return ()
        ExitFailure r -> throwIO $ userError $ "scp error: " ++ show r
  where
    showPath (LocalPath f) = f
    showPath (RemotePath mu h f) = maybe "" (++ "@") mu ++ h ++ ":" ++ f

-- | Runs a command in the given host.
--
-- The call returns immediately. The returned actions
-- read lines of the process stdout and terminate
-- the process.
--
-- Each call of the returned IO action yields potentially
-- a line of output and Nothing when all the output has
-- been consumed and the program has terminated.
--
-- To wait for completion of the command, execute
--
-- > runCommand user host cmd >>= dropWhileM isJust
--
-- To capture the standard error, run as:
--
-- > runCommand user host "(... cmd ...) 2>&1" >>= dropWhileM isJust
--
runCommand :: Maybe String
           -> String
           -> String
           -> IO (IO (Maybe String), IO())
runCommand muser host cmd = do
    -- Connect to the remote host.
    withFile "/dev/null" ReadWriteMode $ \dev_null -> do
      (_, Just sout, ~(Just _), ph) <- createProcess (proc "ssh"
        [ maybe "" (++ "@") muser ++ host
        , "-o", "UserKnownHostsFile=/dev/null"
        , "-o", "StrictHostKeyChecking=no"
        , "--", cmd ])
        { std_out = CreatePipe
        , std_err = UseHandle dev_null
        , std_in = UseHandle dev_null
        }
      hSetBuffering sout LineBuffering
      out <- hGetContents sout
      _ <- forkIO $ void $ evaluate (length out)
      r <- newIORef (lines out)
      return ( atomicModifyIORef' r $ \case
                 []     -> ([], Nothing)
                 x : xs -> (xs, Just x )
             , void $ waitForProcess ph
             )
