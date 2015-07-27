-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}

module HA.Autoboot.Tests
  ( tests
  , ignitionArguments__static -- in order to make -Wall happy
  , ignitionArguments__sdict
  ) where

import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Static ( closureCompose )
import Control.Monad ( replicateM, replicateM_, unless )
import Control.Exception (SomeException(..))
import qualified Control.Exception as Exception
import Data.Binary
import Data.Typeable
import Data.Foldable (forM_)

import GHC.Generics
import System.IO.Unsafe (unsafePerformIO)
import Network.Transport

import HA.Network.RemoteTables (haRemoteTable)
import HA.Process (tryRunProcess)
import HA.Startup hiding (__remoteTable)
import Test.Transport
import Test.Framework


dummyRCStarted :: MVar ()
dummyRCStarted = unsafePerformIO newEmptyMVar
{-# NOINLINE dummyRCStarted #-}

data IgnitionArguments = IgnitionArguments
  { _stationNodes :: [NodeId]
  } deriving (Generic, Typeable)

instance Binary IgnitionArguments

ignitionArguments :: [NodeId] -> IgnitionArguments
ignitionArguments = IgnitionArguments

dummyRC :: IgnitionArguments
        -> ProcessId
        -> ProcessId
        -> Process ()
dummyRC _argv _eq _mm = do
  liftIO $ putMVar dummyRCStarted ()
  receiveWait []

remotable [ 'ignitionArguments, 'dummyRC ]

tests :: AbstractTransport -> IO [TestTree]
tests transport =
  return [ testSuccess "autoboot-simple" $ mkAutobootTest (getTransport transport)
         ]

-- | Test that cluster could be automatically booted after a failure
-- without any manual interaction.
mkAutobootTest :: Transport -- ^ Nodes on which to start the tracking stations
               -> IO ()
mkAutobootTest transport = withTmpDirectory $ do
    -- 0. Run autoboot on 5 nodes
    nids <- replicateM 5 $ newLocalNode transport $ __remoteTable $ haRemoteTable $ initRemoteTable
    let args = ( False :: Bool
               , map localNodeId nids
               , 1000 :: Int
               , 1000000 :: Int
               , $(mkClosure 'dummyRC) $ IgnitionArguments (map localNodeId nids)
               , 8*1000000 :: Int
               )
    node <- newLocalNode transport $ __remoteTable $ haRemoteTable $ initRemoteTable


    runProcess node $ do
      -- 1. Autoboot cluster
      liftIO $ autobootCluster nids

      -- 2. Run ignition once
      result <- call $(functionTDict 'ignition) (localNodeId $ head nids) $
                     $(mkClosure 'ignition) args
      case result of
        Just (added, _, members, newNodes) -> liftIO $ do
          if added then do
            putStrLn "The following nodes joined successfully:"
            mapM_ print newNodes
          else
            putStrLn "No new node could join the group."
          putStrLn ""
          putStrLn "The following nodes were already in the group:"
          mapM_ print members
        Nothing -> return ()

      -- 3. Wait RC to spawn.
      liftIO $ takeMVar dummyRCStarted

      -- 4. Instead of stopping the node we kill all processes. This is a way of
      -- simulating a node dying and coming back again without actually ending
      -- the unix process. Creating a new node on the same unix process would
      --  assign a different NodeId to it, and this in turn changes the location
      -- where the persisted state is expected to be.
      lock <- liftIO $ newEmptyMVar
      forM_ nids $ \lnid -> spawnLocal $ liftIO $ do
        v <- terminateLocalProcesses lnid Nothing
        unless v $ putStrLn "some processes still alive"
        putMVar lock ()
      liftIO $ replicateM_ n $ takeMVar lock

      -- 5. run autoboot once again
      liftIO $ autobootCluster nids

      -- 6. wait for RC to spawn
      liftIO $ takeMVar dummyRCStarted

  where
    n = 5
    rcClosure = $(mkStaticClosure 'dummyRC) `closureCompose`
                  $(mkStaticClosure 'ignitionArguments)

    autobootCluster nids = forM_ nids $ \lnid ->
      Exception.catch (tryRunProcess lnid $ autoboot rcClosure)
                      (\(_ :: SomeException) -> return ())

