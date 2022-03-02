-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- An interface for writing distributed tests.
--
-- A hardcoded @dev@ user is employed for copying files and executing
-- commands on the various hosts.
--
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
module Control.Distributed.Commands.Management
  ( Provider(..)
  , Host(..)
  , copyFiles
  , copyFilesMove
  , systemThere
  , systemThereAsUser
  , systemLocal
  , withHosts
  , withHostNames
  , HostName
  ) where

import Control.Distributed.Commands (scp, ScpPath(..))
import qualified Control.Distributed.Commands as C

import Control.Concurrent.Async.Lifted
import Control.Exception (bracket, throwIO)
import Control.Monad
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import Data.Either (lefts)
import Data.Function (fix)
import Data.List (isPrefixOf)
import Network (HostName)
import System.IO


-- | Interface to a provider of hosts in the cloud.
newtype Provider = Provider
    { createHost :: IO Host
    }

-- | Interface to a host of a 'Provider'.
data Host = Host
   { destroy     :: IO ()
   , shutdown    :: IO ()
   , powerOff    :: IO ()
   , powerOn     :: IO ()
   , hostNameOf  :: HostName
   }

-- | @copyFiles from tos [(s0,d0),...,(sn,dn)]@ copies files from a host to
-- other hosts.
--
-- Thus, the file or folder at path @s0@ on @from@ is copied to path @d0@ on all
-- of @tos@. The file or folder at path @s1@ on @from@ is copied to path @d1@ on
-- all of @tos@ again, and so on up to @sn@ and @dn@.
--
copyFiles :: HostName -> [HostName] -> [(FilePath, FilePath)] -> IO ()
copyFiles from tos paths = do
    bracket
      (mapM async [ scp (toScpPath from pfrom) (toScpPath to pto)
                  | (pfrom, pto) <- paths, to <- tos
                  ])
      (mapM_ waitCatch)
      (mapM waitCatch) >>= mapM_ throwIO . lefts
  where
    toScpPath h p = if isLocalHost h then LocalPath p
                           else RemotePath (Just "dev") h p

-- | Just like 'copyFiles' but instead of directly @scp@ing to the
-- destination location, it uses the default user directory at the
-- host location and then @mv@s the file. This can be useful in case
-- of permission issues.
copyFilesMove :: HostName
              -- ^ Source host
              -> [HostName]
              -- ^ Destination hosts
              -> [(FilePath, FilePath, FilePath)]
              -- ^ @[(sourceLocation, destinationLocation, name)]@
              --
              -- @ [("/usr/lib64/foo.so", "/lib64/foo.so", "foo.so")]@
              --
              -- The @name@ is useful if we're copying whole
              -- directories as it lets us know what to move out from
              -- the default directory.
              -> IO ()
copyFilesMove from tos paths = do
  bracket
    (mapM async [ C.scpMove (toScpPath from pfrom) (toScpPath to pto) name
                | (pfrom, pto, name) <- paths, to <- tos
                ])
    (mapM_ waitCatch)
    (mapM waitCatch) >>= mapM_ throwIO . lefts
  where
    toScpPath h p = if isLocalHost h then LocalPath p
                           else RemotePath (Just "dev") h p

-- | This is defined so we can act on the local host without
-- specifying a user. Otherwise, the library user needs to define
-- a user dev on the local host.
--
-- XXX: Find a better way to write the API so we don't need to
-- define @isLocalHost@.
--
isLocalHost :: String -> Bool
isLocalHost h = h == "localhost" || "127." `isPrefixOf` h

-- | @systemThere ms command@ runs @command@ in a shell on hosts @ms@ and waits
-- until it completes.
systemThere :: [HostName] -> String -> IO ()
systemThere = systemThere' Nothing

-- | Like @systemThere@ but allows to specify the user to run the command.
systemThereAsUser :: String -> [HostName] -> String -> IO ()
systemThereAsUser = systemThere' . Just

systemThere' :: Maybe String -> [HostName] -> String -> IO ()
systemThere' muser ips cmd = bracket
    (forM ips $ \h -> async $
      (maybe C.systemThere C.systemThereAsUser (muser `mplus` host_user h)
                                               h cmd
      ) >>= \cmd_getLine -> fix $ \loop ->
        cmd_getLine >>= \case
          Left ExitSuccess -> return ()
          Left ec ->
            throwIO $ userError $
              "Command " ++ (show cmd) ++ " failed with exit code " ++ (show ec)
          Right line ->
            hPutStrLn stderr line >> loop
    )
    (mapM_ waitCatch)
    (mapM waitCatch) >>= mapM_ throwIO . lefts
  where
    host_user h = if isLocalHost h then Nothing else Just "dev"

-- | @systemThere command@ runs @command@ in a shell on the local host and waits
-- until it completes.
systemLocal :: String -> IO ()
systemLocal cmd = bracket
    (async $ C.systemLocal cmd
      >>= C.waitForCommand_ >>= \case
        ExitSuccess -> return ()
        ExitFailure ec -> throwIO $ userError $
          "Command " ++ (show cmd) ++ " failed with exit code " ++ (show ec)
    )
    (void . waitCatch)
    waitCatch >>= either throwIO return

-- | @withHosts cp n action@ creates @n@ hosts from provider @cp@
-- and then it executes the given @action@. Upon termination of the actions
-- the hosts are destroyed.
withHosts :: Provider -> Int -> ([Host] -> IO a) -> IO a
withHosts cp n action = go n []
  where
    go 0 acc = mapM wait acc >>= action
    go i acc = bracket (async $ createHost cp)
                       (wait >=> destroy)
                       (go (i-1) . (: acc))

-- | Like @withHosts@ but it passes 'HostName's instead of 'Hosts' to the
-- given action.
withHostNames :: Provider -> Int -> ([HostName] -> IO a) -> IO a
withHostNames cp n action = withHosts cp n (action . fmap hostNameOf)
