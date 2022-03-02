-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This module provides scp and ssh conveniently wrapped to use them
-- in scripts.
--

{-# LANGUAGE LambdaCase #-}
module Control.Distributed.Commands
  ( systemThere
  , systemThereAsUser
  , systemLocal
  , scp
  , scpMove
  , ScpPath(..)
  , waitForCommand
  , waitForCommand_
  )
  where

import Control.Concurrent (forkIO)
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Distributed.Commands.Internal.Log (isVerbose)
import Control.Exception (throwIO)
import Control.Monad (void, forM_)
import System.Exit (ExitCode(..))
import System.IO (hGetContents, IOMode(..), withFile, stderr)
import System.Process
    ( StdStream(..)
    , proc
    , shell
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
      dcVerbose <- isVerbose
      let outputHandle = if dcVerbose then stderr else dev_null
      (_, _, _, ph) <- createProcess
        (proc "scp" [ "-r"
                    , "-v"
                    , "-o", "UserKnownHostsFile=/dev/null"
                    , "-o", "StrictHostKeyChecking=no"
                    , showPath src
                    , showPath dst
                    ])
        { std_in  = UseHandle dev_null
        , std_out = UseHandle outputHandle
        , std_err = UseHandle outputHandle
        }
      ret <- waitForProcess ph
      case ret of
        ExitSuccess -> return ()
        ExitFailure r -> throwIO $ userError $ "scp exit code " ++ show r
  where
    showPath (LocalPath f) = f
    showPath (RemotePath mu h f) = maybe "" (++ "@") mu ++ h ++ ":" ++ f

-- | @sc src dst fileName@
--
-- Copies files with @scp@ but instead of using the destination
-- directly, it @mv@s the file from the default directory. If the
-- destination is local, falls back to 'scp'.
scpMove :: ScpPath -> ScpPath -> FilePath -> IO ()
scpMove src (RemotePath _ host path) name = do
  (_, _, _, ph) <- createProcess $
    proc "scp" [ "-r"
               , "-o", "UserKnownHostsFile=/dev/null"
               , "-o", "StrictHostKeyChecking=no"
               , showPath src
               , host ++ ":"
               ]
  ret <- waitForProcess ph
  case ret of
    ExitSuccess -> return ()
    ExitFailure r -> throwIO $ userError $ "scp exit code " ++ show r
  (_, _, _, ph') <- createProcess $
    proc "ssh" [ "-o", "UserKnownHostsFile=/dev/null"
               , "-o", "StrictHostKeyChecking=no"
               , host
               , "mv " ++ name ++ " " ++ path
               ]
  ret' <- waitForProcess ph'
  case ret' of
    ExitSuccess -> return ()
    ExitFailure r -> throwIO $ userError $ "ssh exit code " ++ show r
  where
    showPath (LocalPath f) = f
    showPath (RemotePath mu h f) = maybe "" (++ "@") mu ++ h ++ ":" ++ f
scpMove src dst _ = scp src dst

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
      dcVerbose <- isVerbose
      let outputHandle = if dcVerbose then stderr else dev_null
      (_, Just sout, ~(Just _), phandle) <- createProcess (proc "ssh"
        [ maybe "" (++ "@") muser ++ host
        , "-v"
        , "-o", "UserKnownHostsFile=/dev/null"
        , "-o", "StrictHostKeyChecking=no"
        , "--", cmd ])
        { std_out = CreatePipe
        , std_err = UseHandle outputHandle
        }
      out <- hGetContents sout
      chan <- newChan
      void $ forkIO $ void $ do
        forM_ (lines out) $ \l ->
          writeChan chan (Right l)
        ec <- waitForProcess phandle
        writeChan chan (Left ec)
      return $ readChan chan

-- | Like 'systemThere' but runs the command in the local host.
systemLocal :: String -> IO (IO (Either ExitCode String))
systemLocal cmd = do
    -- Run the command locally.
    withFile "/dev/null" ReadWriteMode $ \dev_null -> do
      (_, Just sout, ~(Just _), phandle) <- createProcess (shell cmd)
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

-- | Collects the input of a command started with 'systemThere' until the
-- command completes.
--
-- It takes as argument the action used to read the input from the process.
waitForCommand :: IO (Either ExitCode String) -> IO ([String], ExitCode)
waitForCommand rio = go id
  where
    go f = rio >>= either (\ec -> return (f [], ec)) (\x -> go $ f . (x :))

-- | Like 'waitForCommand' but only yields the exit code.
waitForCommand_ :: IO (Either ExitCode String) -> IO ExitCode
waitForCommand_ rio = rio >>= either return (const $ waitForCommand_ rio)
