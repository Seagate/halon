-- | An interface for writing distributed tests.
--
-- A hardcoded @dev@ user is employed for copying files and executing
-- commands in the various machines.
--
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Control.Distributed.Test
  ( CloudProvider(..)
  , Machine(..)
  , copyFilesTo
  , runIn
  , withMachines
  , withMachineIPs
  , IP(..)
  ) where

import Control.Distributed.Commands (scp, ScpPath(..), runCommand)

import Control.Concurrent.Async.Lifted
import Control.Exception (bracket, throwIO)
import Control.Monad (forM, (>=>))
import Data.Either (lefts)
import Data.List (isPrefixOf)
import Data.String(IsString)


-- | Interface to a provider of machines in the cloud.
newtype CloudProvider = CloudProvider
    { createMachine :: IO Machine
    }

-- | Interface to a machine of a 'CloudProvider'.
data Machine = Machine
   { destroy     :: IO ()
   , shutdown    :: IO ()
   , powerOff    :: IO ()
   , powerOn     :: IO ()
   , ipOf        :: IP
   }

-- | @copyFilesTo from tos paths@ copies files from a machine to other
-- machines.
copyFilesTo :: IP -> [IP] -> [(FilePath, FilePath)] -> IO ()
copyFilesTo from tos paths = do
    let (pathFrom, pathTos) = unzip paths
    bracket
      (mapM async [ scp (toScpPath from pfrom) (toScpPath to pto)
                  | pfrom <- pathFrom, to <- tos, pto <- pathTos
                  ])
      (mapM_ waitCatch)
      (mapM waitCatch) >>= mapM_ throwIO . lefts
  where
    toScpPath (IP h) p = if isLocalHost h then LocalPath p
                           else RemotePath (Just "dev") h p

isLocalHost :: String -> Bool
isLocalHost h = h == "localhost" || "127.0." `isPrefixOf` h

-- | @runIn ms command@ runs @command@ in a shell in machines @ms@ and waits
-- until it completes.
runIn :: [IP] -> String -> IO ()
runIn ips cmd = bracket (forM ips $ \(IP h) ->
                           async $ runCommand (muser h) h cmd)
                        (mapM_ waitCatch)
                        (mapM waitCatch) >>= mapM_ throwIO . lefts
  where
    muser h = if isLocalHost h then Nothing else Just "dev"

-- | Type of IP addresses
newtype IP = IP String
  deriving IsString

-- | @withMachines cp n action@ creates @n@ machines from provider @cp@
-- and then it executes the given @action@. Upon termination of the actions
-- the machines are destroyed.
withMachines :: CloudProvider -> Int -> ([Machine] -> IO a) -> IO a
withMachines cp n action = go n []
  where
    go 0 acc = mapM wait acc >>= action
    go i acc = bracket (async $ createMachine cp)
                       (wait >=> destroy)
                       (go (i-1) . (: acc))

-- | Like @withMachines@ but it passes 'IP's instead of 'Machines' to the
-- given action.
withMachineIPs :: CloudProvider -> Int -> ([IP] -> IO a) -> IO a
withMachineIPs cp n action = withMachines cp n (action . fmap ipOf)
