-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This module provides scp and ssh conveniently wrapped to use them
-- in scripts.
--

{-# LANGUAGE LambdaCase #-}
module Control.Distributed.Commands
  ( systemThere
  , systemThereAsUser
  , scp
  , ScpPath(..)
  )
  where

import Control.Concurrent (forkIO)
import Control.Exception (throwIO, evaluate)
import Control.Monad (void)
import Data.IORef (atomicModifyIORef', newIORef)
import System.Exit (ExitCode(..))
import System.IO (hGetContents, IOMode(..), withFile)
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

-- | A remote version of 'System.Process.system'.
--
-- Launches a command on the given host and the call returns immediately.
--
-- Each call of the returned IO action yields potentially a line of output and
-- Nothing when all the output has been consumed and the program has terminated.
--
-- To wait for completion of the command, execute
--
-- > systemThere host cmd >>= dropWhileM isJust
--
-- To capture the standard error, run as:
--
-- > systemThere host "(... cmd ...) 2>&1" >>= dropWhileM isJust
--
systemThere :: String       -- ^ The host name or IP address
            -> String       -- ^ A shell command
            -> IO (IO (Maybe String))
               -- ^ An action to read lines of output one at a time
               --
               -- It yields Nothing when all the output has been
               -- consumed.
systemThere = systemThere' Nothing

-- | Like 'systemThere' but it allows to specify a user to run the command.
systemThereAsUser :: String -> String -> String -> IO (IO (Maybe String))
systemThereAsUser = systemThere' . Just

systemThere' :: Maybe String
             -> String
             -> String
             -> IO (IO (Maybe String))
systemThere' muser host cmd = do
    -- Connect to the remote host.
    withFile "/dev/null" ReadWriteMode $ \dev_null -> do
      (_, Just sout, ~(Just _), _) <- createProcess (proc "ssh"
        [ maybe "" (++ "@") muser ++ host
        , "-o", "UserKnownHostsFile=/dev/null"
        , "-o", "StrictHostKeyChecking=no"
        , "--", cmd ])
        { std_out = CreatePipe
        , std_err = UseHandle dev_null
        }
      out <- hGetContents sout
      _ <- forkIO $ void $ evaluate (length out)
      r <- newIORef (lines out)
      return $ atomicModifyIORef' r $ \case
                 []     -> ([], Nothing)
                 x : xs -> (xs, Just x )
