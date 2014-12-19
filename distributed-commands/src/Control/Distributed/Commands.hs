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
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Exception (throwIO)
import Control.Monad (void, forM_)
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
-- then the exit code when all the output has been consumed and the program
-- has terminated.
--
-- To wait for completion of the command, execute
--
-- > systemThere host cmd >>= dropWhileM isRight
--
-- To capture the standard error, run as:
--
-- > systemThere host "(... cmd ...) 2>&1" >>= dropWhileM isRight
--
systemThere :: String       -- ^ The host name or IP address
            -> String       -- ^ A shell command
            -> IO (IO (Either ExitCode String))
               -- ^ An action to read lines of output one at a time
               --
               -- It yields Nothing when all the output has been
               -- consumed.
systemThere = systemThere' Nothing

-- | Like 'systemThere' but it allows to specify a user to run the command.
systemThereAsUser :: String -> String -> String -> IO (IO (Either ExitCode String))
systemThereAsUser = systemThere' . Just

systemThere' :: Maybe String
             -> String
             -> String
             -> IO (IO (Either ExitCode String))
systemThere' muser host cmd = do
    -- Connect to the remote host.
    withFile "/dev/null" ReadWriteMode $ \dev_null -> do
      (_, Just sout, ~(Just _), phandle) <- createProcess (proc "ssh"
        [ maybe "" (++ "@") muser ++ host
        , "-o", "UserKnownHostsFile=/dev/null"
        , "-o", "StrictHostKeyChecking=no"
        , "--", cmd ])
        { std_out = CreatePipe
        , std_err = UseHandle dev_null
        }
      out <- hGetContents sout
      chan <- newChan
      void $ forkIO $ void $ do
        forM_ (lines out) $ \l ->
          writeChan chan (Right l)
        ec <- waitForProcess phandle
        writeChan chan (Left ec)
      return $ readChan chan
