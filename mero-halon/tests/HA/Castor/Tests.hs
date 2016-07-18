{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
module HA.Castor.Tests ( tests, loadInitialData
                       ) where

import Control.Concurrent.MVar
import Control.Distributed.Process
  ( Process
  , RemoteTable
  , liftIO
  , getSelfNode
  , say
  , unClosure
  )
import Control.Distributed.Process.Internal.Types (nullProcessId)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Monad (forM_, join, void)

import Data.List (sort)
import qualified Data.Set as Set

import Network.Transport (Transport)
import Network.CEP
  ( Buffer
  , PhaseM
  , emptyFifoBuffer
  )
import Network.CEP.Testing (runPhase, runPhaseGet)

import HA.Multimap
import HA.Multimap.Implementation (Multimap, fromList)
import HA.Multimap.Process (startMultimap)
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Actions.Mero.Failure.Simple
import Mero.ConfC (PDClustAttr(..))
import HA.RecoveryCoordinator.Actions.Mero.Failure.Internal
import HA.RecoveryCoordinator.Mero
import HA.RecoveryCoordinator.Rules.Mero.Conf (applyStateChanges, stateSet)
import HA.Replicator (RGroup(..))
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import HA.ResourceGraph hiding (__remoteTable)


import RemoteTables (remoteTable)
import TestRunner

import Test.Framework
import qualified Test.Tasty.HUnit as Tasty

import Helper.InitialData
import Helper.Environment (systemHostname)
import Helper.RC
import Data.Proxy
import Data.Typeable


mmSDict :: SerializableDict (MetaInfo, Multimap)
mmSDict = SerializableDict

remotable
  [ 'mmSDict ]

myRemoteTable :: RemoteTable
myRemoteTable = HA.Castor.Tests.__remoteTable remoteTable

rGroupTest :: forall g. (Typeable g, RGroup g)
           => Transport ->  Proxy g -> (StoreChan -> Process ()) -> IO ()
rGroupTest transport _ p = withTmpDirectory $ do
  withLocalNode transport myRemoteTable $ \lnid2 ->
    withLocalNode transport myRemoteTable $ \lnid3 ->
    tryRunProcessLocal transport myRemoteTable $ do
      nid <- getSelfNode
      rGroup <- newRGroup $(mkStatic 'mmSDict) "mmtest" 30 1000000 4000000
                  [nid, localNodeId lnid2, localNodeId lnid3] (defaultMetaInfo, fromList [])
                  >>= unClosure
                  >>= (`asTypeOf` return (undefined :: g (MetaInfo, Multimap)))
      (_, mmchan) <- startMultimap rGroup id
      p mmchan

tests :: (Typeable g, RGroup g) => String -> Transport -> Proxy g -> [TestTree]
tests _host transport pg = map (localOption (mkTimeout $ 10*60*1000000))
  [ testSuccess "failure-sets" $ testFailureSets transport pg
  , testSuccess "failure-sets-2" $ testFailureSets2 transport pg
  , testSuccess "initial-data-doesn't-error" $
      void (loadInitialData transport pg)
  , testSuccess "apply-state-changes" $ testApplyStateChanges transport pg
  -- , testSuccess "large-data" $ largeInitialData host transport
  , testSuccess "controller-failure" $ testControllerFailureDomain transport pg
  ]

fsSize :: (a, Set.Set b) -> Int
fsSize (_, a) = Set.size a

testFailureSets :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testFailureSets transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    (ls', _) <- run ls $ do
      mapM_ goRack (CI.id_racks iData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals iData)
      loadMeroServers filesystem (CI.id_m0_servers iData)
    -- 8 disks, tolerating one disk failure at a time
    let g = lsGraph ls'
        failureSets = generateFailureSets 1 0 0 g (CI.id_m0_globals iData)
    assertMsg "Number of failure sets (100)" $ length failureSets == 9
    assertMsg "Smallest failure set is empty (100)"
      $ fsSize (head failureSets) == 0

    -- 8 disks, two failures at a time
    let failureSets2 = generateFailureSets 2 0 0 g (CI.id_m0_globals iData)
    assertMsg "Number of failure sets (200)" $ length failureSets2 == 37
    assertMsg "Smallest failure set is empty (200)"
      $ fsSize (head failureSets2) == 0
    assertMsg "Next smallest failure set has one disk (200)"
      $ fsSize (failureSets2 !! 1) == 1
  where
    iData = initialData systemHostname "192.0.2" 1 8
            $ defaultGlobals { CI.m0_data_units = 4
                             , CI.m0_failure_set_gen = CI.Dynamic }

testFailureSets2 :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testFailureSets2 transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    (ls', _) <- run ls $ do
      mapM_ goRack (CI.id_racks iData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals iData)
      loadMeroServers filesystem (CI.id_m0_servers iData)
    -- 16 disks, tolerating one disk failure at a time
    let g = lsGraph ls'
        failureSets = generateFailureSets 1 0 0 g (CI.id_m0_globals iData)
    assertMsg "Number of failure sets (100)" $ length failureSets == 17
    assertMsg "Smallest failure set is empty (100)"
      $ fsSize (head failureSets) == 0

    -- 16 disks, two failures at a time
    let failureSets2 = generateFailureSets 2 0 0 g (CI.id_m0_globals iData)
    assertMsg "Number of failure sets (200)" $ length failureSets2 == 137
    assertMsg "Smallest failure set is empty (200)"
      $ fsSize (head failureSets2) == 0
    assertMsg "Next smallest failure set has one disk (200)"
      $ fsSize (failureSets2 !! 1) == 1

    let failureSets010 = generateFailureSets 0 1 0 g (CI.id_m0_globals iData)
    assertMsg "Number of failure sets (010)" $ length failureSets010 == 5
    assertMsg "Smallest failure set is empty (010)"
      $ fsSize (head failureSets010) == 0
    assertMsg "Next smallest failure set has 4 disks and one controller (010)"
      $ fsSize (failureSets010 !! 1) == 5

    let failureSets110 = generateFailureSets 1 1 0 g (CI.id_m0_globals iData)
    assertMsg "Number of failure sets (110)" $ length failureSets110 == 69
    assertMsg "Smallest failure set is empty (110)"
      $ fsSize (head failureSets110) == 0
    assertMsg "Next smallest failure set has 1 disk and zero controllers (110)"
      $ fsSize (failureSets110 !! 1) == 1
  where
    iData = initialData systemHostname "192.0.2" 4 4
            $ defaultGlobals { CI.m0_failure_set_gen = CI.Dynamic }

-- | Load the initial data into local RG and verify that it loads as expected.
--
-- Returns the loaded RG for use by others (@initial-data-gc@).
loadInitialData :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO Graph
loadInitialData transport pg = do
  gmv <- newEmptyMVar
  rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    (ls', _) <- run ls $ do
      -- TODO: the interface address is hard-coded here: currently we
      -- don't use it so it doesn't impact us but in the future we
      -- should also take it as a parameter to the test, just like the
      -- host
      mapM_ goRack (CI.id_racks iData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals iData)
      loadMeroServers filesystem (CI.id_m0_servers iData)
      rg <- getLocalGraph
      let Just updateGraph = onInit (simpleStrategy 2 2 1) rg
      rg' <- updateGraph return
      putLocalGraph rg'
    -- Verify that everything is set up correctly
    bmc <- runGet ls' $ findBMCAddress myHost
    say $ "BMC: " ++ show bmc
    assertMsg "Get BMC Address." $ bmc == Just "192.0.2.1"
    hosts <- runGet ls' $ findHosts ".*"
    assertMsg "Find correct hosts." $ hosts == [myHost]
    hostAttrs <- runGet ls' $ findHostAttrs myHost
    liftIO $ Tasty.assertEqual "Host attributes"
                               (sort [HA_MEMSIZE_MB 4096, HA_CPU_COUNT 8, HA_M0SERVER])
                               (sort hostAttrs)
    (Just fs) <- runGet ls' getFilesystem
    let pool = M0.Pool (M0.f_mdpool_fid fs)
    assertMsg "MDPool is stored in RG"
      $ memberResource pool (lsGraph ls')
    mdpool <- runGet ls' $ lookupConfObjByFid (M0.f_mdpool_fid fs)
    assertMsg "MDPool is findable by Fid"
      $ mdpool == Just pool
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
    assertMsg "Number of storage devices" $ length sdevs == 12
    assertMsg "Number of disks (reached by host)" $ length disksByHost == 12
    assertMsg "Number of disks" $ length disks == 12
    assertMsg "Number of disk versions" $ length dvers1 == 67
    forM_ (getResourcesOfType g :: [M0.PVer]) $ \pver -> do
      let PDClustAttr { _pa_N = paN
                      , _pa_K = paK
                      , _pa_P = paP
                      } = M0.v_attrs pver
      assertMsg "N in PVer" $ CI.m0_data_units (CI.id_m0_globals iData) == paN
      assertMsg "K in PVer" $ CI.m0_parity_units (CI.id_m0_globals iData) == paK
      let dver = [ diskv | rackv <- connectedTo  pver M0.IsParentOf g :: [M0.RackV]
                         , enclv <- connectedTo rackv M0.IsParentOf g :: [M0.EnclosureV]
                         , cntrv <- connectedTo enclv M0.IsParentOf g :: [M0.ControllerV]
                         , diskv <- connectedTo cntrv M0.IsParentOf g :: [M0.DiskV]]
      liftIO $ Tasty.assertEqual "P in PVer" paP $ fromIntegral (length dver)
    liftIO $ putMVar gmv g
  tryTakeMVar gmv >>= \case
    Nothing -> error "HA.Castor.Tests.loadInitialData: gmv empty"
    Just g -> return g
  where
    myHost = Host systemHostname
    iData = initialData systemHostname "192.0.2" 1 12 defaultGlobals

-- | Test that failure domain logic works correctly when we are
testControllerFailureDomain :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testControllerFailureDomain transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    (ls', _) <- run ls $ do
      mapM_ goRack (CI.id_racks iData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals iData)
      loadMeroServers filesystem (CI.id_m0_servers iData)
      rg <- getLocalGraph
      let Just updateGraph = onInit (simpleStrategy 0 1 0) rg
      rg' <- updateGraph return
      putLocalGraph rg'
    -- Verify that everything is set up correctly
    (Just fs) <- runGet ls' getFilesystem
    let mdpool = M0.Pool (M0.f_mdpool_fid fs)
    assertMsg "MDPool is stored in RG"
      $ memberResource mdpool (lsGraph ls')
    mdpool_byFid <- runGet ls' $ lookupConfObjByFid (M0.f_mdpool_fid fs)
    assertMsg "MDPool is findable by Fid"
      $ mdpool_byFid == Just mdpool

    -- Get the non metadata pool
    [pool] <- runGet ls' getPool

    -- We have 4 disks in 4 enclosures.
    hosts <- runGet ls' $ findHosts ".*"
    let g = lsGraph ls'
        pvers = connectedTo pool M0.IsRealOf g :: [M0.PVer]
        racks = connectedTo fs M0.IsParentOf g :: [M0.Rack]
        encls = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Enclosure]) racks
        ctrls = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Controller]) encls
        disks = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Disk]) ctrls

        sdevs = join $ fmap (\r -> connectedTo r Has g :: [StorageDevice]) hosts
        disksByHost = join $ fmap (\r -> connectedFrom M0.At r g :: [M0.Disk]) sdevs

        disk1 = head disks
        dvers1 = connectedTo disk1 M0.IsRealOf g :: [M0.DiskV]

    assertMsg "Number of pvers" $ length pvers == 5
    assertMsg "Number of racks" $ length racks == 1
    assertMsg "Number of enclosures" $ length encls == 4
    assertMsg "Number of controllers" $ length ctrls == 4
    assertMsg "Number of storage devices" $ length sdevs == 16
    assertMsg "Number of disks (reached by host)" $ length disksByHost == 16
    assertMsg "Number of disks" $ length disks == 16
    assertMsg "Number of disk versions" $ length dvers1 == 4
    forM_ (getResourcesOfType g :: [M0.PVer]) $ \pver -> do
      let PDClustAttr { _pa_N = paN
                      , _pa_K = paK
                      , _pa_P = paP
                      } = M0.v_attrs pver
      assertMsg "N in PVer" $ CI.m0_data_units (CI.id_m0_globals iData) == paN
      assertMsg "K in PVer" $ CI.m0_parity_units (CI.id_m0_globals iData) == paK
      let dver = [ diskv | rackv <- connectedTo  pver M0.IsParentOf g :: [M0.RackV]
                         , enclv <- connectedTo rackv M0.IsParentOf g :: [M0.EnclosureV]
                         , cntrv <- connectedTo enclv M0.IsParentOf g :: [M0.ControllerV]
                         , diskv <- connectedTo cntrv M0.IsParentOf g :: [M0.DiskV]]
      liftIO $ Tasty.assertEqual "P in PVer" paP $ fromIntegral (length dver)
  where
    iData = initialData systemHostname "192.0.2" 4 4 defaultGlobals

-- | Test that applying state changes works
testApplyStateChanges :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testApplyStateChanges transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    (ls, _) <- run ls $ do
      mapM_ goRack (CI.id_racks iData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals iData)
      loadMeroServers filesystem (CI.id_m0_servers iData)

    let procs = getResourcesOfType (lsGraph ls) :: [M0.Process]

    (ls, _) <- run ls $ applyStateChanges $ (\p -> stateSet p M0.PSOnline) <$> procs

    assertMsg "All processes should be online"
      $ length (connectedFrom Is M0.PSOnline (lsGraph ls) :: [M0.Process]) ==
        length procs

    (ls, _) <- run ls $ applyStateChanges $ (\p -> stateSet p M0.PSStopping) <$> procs

    assertMsg "All processes should be stopping"
      $ length (connectedFrom Is M0.PSStopping (lsGraph ls) :: [M0.Process]) ==
        length procs
  where
    iData = initialData systemHostname "192.0.2" 4 4 defaultGlobals

{-
printMem :: IO String
printMem = do
  performGC
  l1 <- fmap (unlines . filter (\x -> any (`isPrefixOf` x) ["VmHWM", "VmRSS"])
                      . lines) (readFile "/proc/self/status")
  stats <- getGCStats
  let l2 = "In use according to GC stats: " ++ show (currentBytesUsed stats `div` (1024 * 1024)) ++ " MB"
      l3 = "HWM according the GC stats: " ++ show (maxBytesUsed stats `div` (1024 * 1024)) ++ " MB"
  return $ unlines [l1,l2,l3]

largeInitialData :: (Typeable g, RGroup g) => String -> Transport -> Proxy g -> IO ()
largeInitialData host transport pg = let
    numDisks = 300
    initD = (initialDataAddr host "192.0.2.2" numDisks)
    myHost = Host systemHostname
  in
    rGroupTest transport pg $ \pid -> do
      me <- getSelfNode
      ls <- emptyLoopState pid (nullProcessId me)
      (ls', _) <- run ls $ do
        -- TODO: the interface address is hard-coded here: currently we
        -- don't use it so it doesn't impact us but in the future we
        -- should also take it as a parameter to the test, just like the
        -- host
        mapM_ goRack (CI.id_racks initD)
        filesystem <- initialiseConfInRG
        loadMeroGlobals (CI.id_m0_globals initD)
        loadMeroServers filesystem (CI.id_m0_servers initD)
        self <- liftProcess $ getSelfPid
        syncGraph $ usend self ()
        liftProcess (expect :: Process ())
        rg <- getLocalGraph
        let Just updateGraph = onInit (simpleStrategy 1 0 0) rg
        rg' <- updateGraph $ \g -> do
          putLocalGraph g
          syncGraph (return ())
          getLocalGraph
        putLocalGraph rg'


      -- Verify that everything is set up correctly
      bmc <- runGet ls' $ findBMCAddress myHost
      assertMsg "Get BMC Address." $ bmc == Just host
      hosts <- runGet ls' $ findHosts ".*"
      assertMsg "Find correct hosts." $ hosts == [myHost]
      hostAttrs <- runGet ls' $ findHostAttrs myHost
      assertMsg "Host attributes"
        $ sort hostAttrs == sort [HA_MEMSIZE_MB 4096, HA_CPU_COUNT 8]
      (Just fs) <- runGet ls' getFilesystem
      let pool = M0.Pool (M0.f_mdpool_fid fs)
      assertMsg "MDPool is stored in RG"
        $ memberResource pool (lsGraph ls')
      mdpool <- runGet ls' $ lookupConfObjByFid (M0.f_mdpool_fid fs)
      assertMsg "MDPool is findable by Fid"
        $ mdpool == Just pool

      say =<< liftIO printMem
      g <- getGraph pid
      let racks = connectedTo fs M0.IsParentOf g :: [M0.Rack]
          encls = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Enclosure]) racks
          ctrls = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Controller]) encls
          disks = join $ fmap (\r -> connectedTo r M0.IsParentOf g :: [M0.Disk]) ctrls
          sdevs = join $ fmap (\r -> connectedTo r Has g :: [StorageDevice]) hosts
          disksByHost = join $ fmap (\r -> connectedFrom M0.At r g :: [M0.Disk]) sdevs

      say =<< liftIO printMem
      liftIO $ Tasty.assertEqual "Numbe of racks" 1 (length racks)
      assertMsg "Number of enclosures" $ length encls == 1
      assertMsg "Number of controllers" $ length ctrls == 1
      assertMsg "Number of storage devices" $ length sdevs == numDisks
      assertMsg "Number of disks (reached by host)" $ length disksByHost == numDisks
      assertMsg "Number of disks" $ length disks == numDisks
-}

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
    mapM_ (registerBMC enclosure) enc_bmc
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
