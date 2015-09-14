{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
module HA.Castor.Tests
  ( tests
  ) where

import Control.Distributed.Process
  ( Process
  , ProcessId
  , RemoteTable
  , spawnLocal
  , liftIO
  , catch
  , getSelfNode
  , say
  , unClosure
  )
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Exception (SomeException, bracket)
import Control.Monad (join)

import Data.List (sort)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Network.Transport (Transport)
import Network.CEP
  ( Buffer(..)
  , PhaseM
  , emptyFifoBuffer
  )
import Network.CEP.Testing (runPhase, runPhaseGet)

import HA.Multimap.Implementation (Multimap, fromList)
import HA.Multimap.Process (multimap)
import HA.Process
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Mero
import HA.RecoveryCoordinator.Rules.Mero
import HA.Replicator (RGroup(..))
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock (MC_RG)
#else
import HA.Replicator.Log (MC_RG)
#endif
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import HA.ResourceGraph hiding (__remoteTable)

import Mero.ConfC (ServiceParams(..))

import RemoteTables (remoteTable)

import Test.Framework

mmSDict :: SerializableDict Multimap
mmSDict = SerializableDict

remotable
  [ 'mmSDict ]

emptyLoopState :: ProcessId -> Process LoopState
emptyLoopState pid = do
  g <- getGraph pid
  return $ LoopState g Map.empty pid Set.empty

myRemoteTable :: RemoteTable
myRemoteTable = HA.Castor.Tests.__remoteTable remoteTable

-- | Run the given action on a newly created local node.
withLocalNode :: Transport -> (LocalNode -> IO a) -> IO a
withLocalNode transport action =
  bracket
    (newLocalNode transport (myRemoteTable))
    -- FIXME: Why does this cause gibberish to be output?
    -- closeLocalNode
    (const (return ()))
    action

-- | FIXME: Why do we need tryRunProcess?
tryRunProcessLocal :: Transport -> Process () -> IO ()
tryRunProcessLocal transport process =
  withTmpDirectory $
    withLocalNode transport $ \node ->
      tryRunProcess node process

rGroupTest :: Transport -> (ProcessId -> Process ()) -> IO ()
rGroupTest transport p =
  tryRunProcessLocal transport $
    flip catch (\e -> liftIO $ print (e :: SomeException)) $ do
      nid <- getSelfNode
      rGroup <- newRGroup $(mkStatic 'mmSDict) 20 1000000 [nid] (fromList [])
                  >>= unClosure
                  >>= (`asTypeOf` return (undefined :: MC_RG Multimap))
      mmpid <- spawnLocal $ catch (multimap rGroup) $
        (\e -> liftIO $ print (e :: SomeException))
      p mmpid

tests :: Transport -> [TestTree]
tests transport = map (localOption (mkTimeout $ 60*1000000))
  [ testSuccess "failure-sets" $ testFailureSets transport
  , testSuccess "initial-data-doesn't-error" $ loadInitialData transport
  ]

testFailureSets :: Transport -> IO ()
testFailureSets transport = rGroupTest transport $ \pid -> do
    ls <- emptyLoopState pid
    (ls', _) <- run ls $ do
      mapM_ goRack (CI.id_racks initialData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals initialData)
      loadMeroServers filesystem (CI.id_m0_servers initialData)
    -- 8 disks, tolerating one disk failure at a time
    failureSets <- runGet ls' $ generateFailureSets 1 0 0
    say $ show failureSets
    assertMsg "Number of failure sets (100)" $ Set.size failureSets == 9
    assertMsg "Smallest failure set is empty (100)"
      $ Set.elemAt 0 failureSets == Set.empty

    -- 8 disks, two failures at a time
    failureSets2 <- runGet ls' $ generateFailureSets 2 0 0
    assertMsg "Number of failure sets (200)" $ Set.size failureSets2 == 37
    assertMsg "Smallest failure set is empty (200)"
      $ Set.elemAt 0 failureSets2 == Set.empty
    assertMsg "Next smallest failure set has one disk (200)"
      $ Set.size (Set.elemAt 1 failureSets2) == 1


loadInitialData :: Transport -> IO ()
loadInitialData transport = rGroupTest transport $ \pid -> do
    ls <- emptyLoopState pid
    (ls', _) <- run ls $ do
      mapM_ goRack (CI.id_racks initialData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals initialData)
      loadMeroServers filesystem (CI.id_m0_servers initialData)
      failureSets <- generateFailureSets 2 2 1
      createPoolVersions filesystem failureSets
    -- Verify that everything is set up correctly
    bmc <- runGet ls' $ findBMCAddress myHost
    assertMsg "Get BMC Address." $ bmc == Just "192.0.2.1"
    hosts <- runGet ls' $ findHosts ".*"
    assertMsg "Find correct hosts." $ hosts == [myHost]
    hostAttrs <- runGet ls' $ findHostAttrs myHost
    assertMsg "Host attributes"
      $ sort hostAttrs == sort [HA_MEMSIZE_MB 4096, HA_CPU_COUNT 8]
    (Just fs) <- runGet ls' getFilesystem

    -- We have 8 disks in only a single enclosure. Thus, each disk should
    -- be in 29 pool versions (1 with 0 failures, 7 with 1 failure, 21 with
    -- 2 failures)

    let g = lsGraph ls'
        racks = connectedTo fs M0.IsParentOf g :: [M0.Rack]
        encls = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Enclosure]) racks
        ctrls = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Controller]) encls
        disks = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Disk]) ctrls

        sdevs = join $ fmap (\r -> connectedTo r Has g :: [StorageDevice]) hosts
        disksByHost = join $ fmap (\r -> connectedFrom M0.At r g :: [M0.Disk]) sdevs

        disk1 = head disks
        dvers1 = connectedTo disk1 M0.IsRealOf g :: [M0.DiskV]


    assertMsg "Number of racks" $ length racks == 1
    assertMsg "Number of enclosures" $ length encls == 1
    assertMsg "Number of controllers" $ length ctrls == 1
    assertMsg "Number of storage devices" $ length sdevs == 8
    assertMsg "Number of disks (reached by host)" $ length disksByHost == 8
    assertMsg "Number of disks" $ length disks == 8
    say $ show dvers1
    assertMsg "Number of disk versions" $ length dvers1 == 29


  where
    myHost = Host "primus.example.com"

run :: forall g. g
    -> PhaseM g Int ()
    -> Process (g, [(Buffer, Int)])
run ls = runPhase ls (0 :: Int) emptyFifoBuffer

runGet :: forall g a. g -> PhaseM g (Maybe a) a -> Process a
runGet = runPhaseGet

goRack :: forall l. CI.Rack
       -> PhaseM LoopState l ()
goRack (CI.Rack{..}) = let rack = Rack rack_idx in do
  registerRack rack
  mapM_ (goEnc rack) rack_enclosures
goEnc :: forall l. Rack
      -> CI.Enclosure
      -> PhaseM LoopState l ()
goEnc rack (CI.Enclosure{..}) = let
    enclosure = Enclosure enc_id
  in do
    registerEnclosure rack enclosure
    registerBMC enclosure enc_bmc
    mapM_ (goHost enclosure) enc_hosts
goHost :: forall l. Enclosure
       -> CI.Host
       -> PhaseM LoopState l ()
goHost enc (CI.Host{..}) = let
    host = Host h_fqdn
    mem = fromIntegral h_memsize
    cpucount = fromIntegral h_cpucount
    attrs = [HA_MEMSIZE_MB mem, HA_CPU_COUNT cpucount]
  in do
    registerHost host
    locateHostInEnclosure host enc
    mapM_ (setHostAttr host) attrs
    mapM_ (registerInterface host) h_interfaces

-- | Sample initial data for test purposes
initialData :: CI.InitialData
initialData = CI.InitialData {
  CI.id_racks = [
    CI.Rack {
      CI.rack_idx = 1
    , CI.rack_enclosures = [
        CI.Enclosure {
          CI.enc_idx = 1
        , CI.enc_id = "enclosure1"
        , CI.enc_bmc = CI.BMC "192.0.2.1" "admin" "admin"
        , CI.enc_hosts = [
            CI.Host {
              CI.h_fqdn = "primus.example.com"
            , CI.h_memsize = 4096
            , CI.h_cpucount = 8
            , CI.h_interfaces = [
                CI.Interface {
                  CI.if_macAddress = "10-00-00-00-00"
                , CI.if_network = CI.Data
                , CI.if_ipAddrs = ["192.0.2.2"]
                }
              ]
            }
          ]
        }
      ]
    }
  ]
, CI.id_m0_globals = CI.M0Globals {
    CI.m0_datadir = "/var/mero"
  , CI.m0_t1fs_mount = "/mnt/mero"
  , CI.m0_data_units = 8
  , CI.m0_parity_units = 2
  , CI.m0_pool_width = 8
  , CI.m0_max_rpc_msg_size = 65536
  , CI.m0_uuid = "096051ac-b79b-4045-a70b-1141ca4e4de1"
  , CI.m0_min_rpc_recvq_len = 16
  , CI.m0_lnet_nid = "auto"
  , CI.m0_be_segment_size = 536870912
  , CI.m0_md_reduncandy = 2
  }
, CI.id_m0_servers = [
    CI.M0Host {
      CI.m0h_fqdn = "primus.example.com"
    , CI.m0h_mem_as = 1
    , CI.m0h_mem_rss = 1
    , CI.m0h_mem_stack = 1
    , CI.m0h_mem_memlock = 1
    , CI.m0h_cores = 0xf
    , CI.m0h_services = [
        CI.M0Service {
          CI.m0s_type = "confd"
        , CI.m0s_endpoints = ["lnet:192.0.2.1@tcp:12345:41:101"]
        , CI.m0s_params = SPConfDBPath "/var/mero/confd"
        }
      , CI.M0Service {
          CI.m0s_type = "mds"
        , CI.m0s_endpoints = ["lnet:192.0.2.1@tcp:12345:41:201"]
        , CI.m0s_params = SPUnused
        }
      , CI.M0Service {
          CI.m0s_type = "ios"
        , CI.m0s_endpoints = ["lnet:192.0.2.1@tcp:12345:41:401"]
        , CI.m0s_params = SPUnused
        }
      ]
    , CI.m0h_devices = fmap
        (\i -> CI.M0Device ("wwn" ++ show i) 4 64000 ("/dev/loop" ++ show i))
        [(0:: Int) ..7]
    }
  ]
}
