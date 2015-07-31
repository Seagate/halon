{-# LANGUAGE TemplateHaskell #-}
module HA.Autoboot.Tests
  ( tests
  ) where

import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Static ( closureCompose )
import Control.Monad ( replicateM )
import Control.Exception (SomeException(..))
import qualified Control.Exception as Exception
import Data.Foldable (forM_)
import qualified Data.Set as Set

import Network.Transport (Transport)

import HA.RecoveryCoordinator.Definitions
import HA.RecoveryCoordinator.Mero
import HA.Network.RemoteTables (haRemoteTable)
import Mero.RemoteTables (meroRemoteTable)

import qualified HA.Services.EQTracker as EQT
import HA.NodeUp ( nodeUp )
import HA.Process (tryRunProcess)
import HA.Startup hiding (__remoteTable)
import Test.Framework

myRemoteTable :: RemoteTable
myRemoteTable = haRemoteTable $ meroRemoteTable initRemoteTable

tests :: Transport -> [TestTree]
tests transport =
  [ testSuccess "eqt-receive-all-tracking-stations"
                $ eqtReceiveAllStations transport
  , testSuccess "eqt-receive-startions-at-start"
                $ eqtReceiveStationsAtStart transport
  ]

eqtReceiveAllStations :: Transport -> IO ()
eqtReceiveAllStations transport = withTmpDirectory $ do
  (node, nids) <- bootupCluster transport (Right 5)
  runProcess node $ do
    nodeUp (map localNodeId nids, 1000000)
    Just eq <- whereis EQT.name
    self <- getSelfPid
    send eq (EQT.ReplicaRequest self)
    EQT.ReplicaReply (EQT.ReplicaLocation _ xs) <- expect
    True <- return $ Set.fromList xs == (Set.fromList $ map localNodeId nids)
    return ()

eqtReceiveStationsAtStart :: Transport -> IO ()
eqtReceiveStationsAtStart transport = withTmpDirectory $ do
  nids <- replicateM 5 $ newLocalNode transport $ myRemoteTable
  node <- newLocalNode transport $ myRemoteTable
  lock <- newEmptyMVar
  _    <- forkProcess node $ do
    nodeUp (map localNodeId nids, 1000000)
    Just eq <- whereis EQT.name
    self <- getSelfPid
    send eq (EQT.ReplicaRequest self)
    EQT.ReplicaReply (EQT.ReplicaLocation _ xs) <- expect
    liftIO $ putMVar lock $ Set.fromList xs == (Set.fromList $ map localNodeId nids)
  _ <- bootupCluster transport (Left nids)
  True <- takeMVar lock
  return ()

-- | Startup cluster. This function autoboots required number of nodes
-- and return a head node (that is not part of the cluster), and list
-- of tracking stations.
bootupCluster :: Transport
              -> (Either [LocalNode] Int) -- ^ list of nodes to bootstrap or number
                                          --   of nodes to bootstrap
              -> IO (LocalNode, [LocalNode])
bootupCluster transport en = do
    nids <- case en of
              Left ns -> return ns
              Right n -> replicateM n $ newLocalNode transport $ myRemoteTable
    let args = ( False :: Bool
               , map localNodeId nids
               , 1000 :: Int
               , 1000000 :: Int
               , $(mkClosure 'recoveryCoordinator) $ IgnitionArguments (map localNodeId nids)
               , 8*1000000 :: Int
               )
    node <- newLocalNode transport $ myRemoteTable
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
    return (node,nids)

-- | Start dummy recovery coordinator
rcClosure :: Closure ([NodeId] -> ProcessId -> ProcessId -> Process ())
rcClosure = $(mkStaticClosure 'recoveryCoordinator) `closureCompose`
               $(mkStaticClosure 'ignitionArguments)

-- | Autoboot helper cluster
autobootCluster :: [LocalNode] -> IO ()
autobootCluster nids = forM_ nids $ \lnid ->
  Exception.catch (tryRunProcess lnid $ autoboot rcClosure)
                  (\(_ :: SomeException) -> return ())
