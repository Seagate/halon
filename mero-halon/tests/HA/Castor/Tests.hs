{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
module HA.Castor.Tests ( tests ) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Distributed.Process
  ( Process
  , RemoteTable
  , liftIO
  , getSelfNode
  , unClosure
  )
import Control.Distributed.Process.Internal.Types (nullProcessId)
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Monad (forM_, join, unless)

import Data.List (partition)
import Data.Foldable (for_)
import qualified Data.Set as Set

import Network.Transport (Transport)
import Network.CEP
  ( Application(..)
  , Buffer
  , PhaseM
  , emptyFifoBuffer
  )
import Network.CEP.Testing (runPhase, runPhaseGet)

import HA.Multimap
import HA.Multimap.Implementation (Multimap, fromList)
import HA.Multimap.Process (startMultimap)
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Mero.Actions.Failure
import HA.RecoveryCoordinator.Mero.Failure.Simple
import HA.RecoveryCoordinator.Castor.Cluster.Events
import HA.RecoveryCoordinator.Castor.Cluster.Actions
import qualified HA.RecoveryCoordinator.Mero.Transitions.Internal as TrI
import Mero.ConfC (PDClustAttr(..))
import HA.RecoveryCoordinator.Mero
import HA.RecoveryCoordinator.Mero.State (applyStateChanges, stateSet)
import qualified HA.RecoveryCoordinator.RC.Rules as RC
import HA.Replicator (RGroup(..))
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import HA.ResourceGraph hiding (__remoteTable)
import qualified Mero.ConfC as ConfC


import RemoteTables (remoteTable)
import TestRunner

import Test.Framework
import qualified Test.Tasty.HUnit as Tasty

import Helper.InitialData
import Helper.RC
import Data.List  (nub)
import Data.Maybe (catMaybes)
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

tests :: (Typeable g, RGroup g) => Transport -> Proxy g -> [TestTree]
tests transport pg = map (localOption (mkTimeout $ 10*60*1000000))
  [ testSuccess "failure-sets" $ testFailureSets transport pg
  , testSuccess "failure-sets-2" $ testFailureSets2 transport pg
  , testSuccess "failure-sets-formulaic" $ testFailureSetsFormulaic transport pg
  , testSuccess "apply-state-changes" $ testApplyStateChanges transport pg
  , testSuccess "controller-failure" $ testControllerFailureDomain transport pg
  , testClusterLiveness transport pg
  ]

fsSize :: (a, Set.Set b) -> Int
fsSize (_, a) = Set.size a

testFailureSets :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testFailureSets transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    settings <- liftIO defaultInitialDataSettings
    iData <- liftIO . initialData $ settings
               { _id_drives = 8
               , _id_globals = defaultGlobals { CI.m0_data_units = 4 } }
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

testFailureSets2 :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testFailureSets2 transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    settings <- liftIO defaultInitialDataSettings
    iData <- liftIO . initialData $ settings
               { _id_servers = 4, _id_drives = 4 }
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

testFailureSetsFormulaic :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testFailureSetsFormulaic transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    settings <- liftIO defaultInitialDataSettings
    iData <- liftIO . initialData $ settings
               { _id_servers = 4
               , _id_drives = 4
               , _id_globals = defaultGlobals { CI.m0_failure_set_gen = CI.Formulaic sets} }
    (ls', _) <- run ls $ do
      mapM_ goRack (CI.id_racks iData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals iData)
      loadMeroServers filesystem (CI.id_m0_servers iData)
      Just (Monolithic update) <- getCurrentGraphUpdateType
      modifyLocalGraph update

    let g = lsGraph ls'

    let ppvers = [(pool, pvers) | Just (root :: M0.Root) <- [connectedTo Cluster Has g]
                                , Just (profile :: M0.Profile) <- [connectedTo root M0.IsParentOf g]
                                , fs :: M0.Filesystem <- connectedTo profile M0.IsParentOf g
                                , pool :: M0.Pool     <- connectedTo fs M0.IsParentOf g
                                , let pvers :: [M0.PVer] = connectedTo pool M0.IsRealOf g
                                ]
    for_ ppvers $ \(_, pvers) -> do
      unless (Prelude.null pvers) $ do -- skip metadata pool
        let (actual, formulaic) = partition (\(M0.PVer _ t) -> case t of M0.PVerActual{} -> True ; _ -> False) pvers
        liftIO $ Tasty.assertEqual "There should be only one actual PVer for Pool" 1 (length actual)
        liftIO $ Tasty.assertEqual "Each formula should be presented" (length sets) (length formulaic)
        let [M0.PVer fid _] = actual
        for_ formulaic $ \f -> do
          liftIO $ Tasty.assertEqual "base fid should be equal to actual pver" fid (M0.v_base $ M0.v_type f)
        let sets2 = Set.fromList $ map (\(M0.PVer _ (M0.PVerFormulaic _ a _)) -> a) formulaic
        liftIO $ Tasty.assertEqual "all formulas should be presented" (Set.fromList sets) sets2
        let ids = Set.fromList $ map (\(M0.PVer _ (M0.PVerFormulaic i _ _)) -> i) formulaic
        liftIO $ Tasty.assertBool "all ids should be unique" (Set.size ids == length sets)
  where
    sets = [[0,0,0,0,1],[0,0,0,1,1]]

-- | Test that failure domain logic works correctly when we are
testControllerFailureDomain :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testControllerFailureDomain transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    settings <- liftIO defaultInitialDataSettings
    iData <- liftIO . initialData $ settings { _id_servers = 4, _id_drives = 4 }
    (ls', _) <- run ls $ do
      mapM_ goRack (CI.id_racks iData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals iData)
      loadMeroServers filesystem (CI.id_m0_servers iData)
      rg <- getLocalGraph
      let Iterative update = simpleUpdate 0 1 0
      let Just updateGraph = update rg
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
        enc   = catMaybes $ fmap (\r -> connectedFrom Has r g :: Maybe Enclosure) hosts
        sdevs = join $ fmap (\r -> connectedTo r Has g :: [StorageDevice]) enc
        disksByHost = catMaybes $ fmap (\r -> connectedFrom M0.At r g :: Maybe M0.Disk) sdevs

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
                      } = M0.v_attrs $ (\(M0.PVer _ a) -> a) $ pver
      assertMsg "N in PVer" $ CI.m0_data_units (CI.id_m0_globals iData) == paN
      assertMsg "K in PVer" $ CI.m0_parity_units (CI.id_m0_globals iData) == paK
      let dver = [ diskv | rackv <- connectedTo  pver M0.IsParentOf g :: [M0.RackV]
                         , enclv <- connectedTo rackv M0.IsParentOf g :: [M0.EnclosureV]
                         , cntrv <- connectedTo enclv M0.IsParentOf g :: [M0.ControllerV]
                         , diskv <- connectedTo cntrv M0.IsParentOf g :: [M0.DiskV]]
      liftIO $ Tasty.assertEqual "P in PVer" paP $ fromIntegral (length dver)

-- | Test that applying state changes works
testApplyStateChanges :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testApplyStateChanges transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls0 <- emptyLoopState pid (nullProcessId me)
    settings <- liftIO defaultInitialDataSettings
    iData <- liftIO . initialData $ settings { _id_servers = 4, _id_drives = 4 }
    (ls1, _) <- run ls0 $ do
      mapM_ goRack (CI.id_racks iData)
      filesystem <- initialiseConfInRG
      loadMeroGlobals (CI.id_m0_globals iData)
      loadMeroServers filesystem (CI.id_m0_servers iData)
      RC.initialRule (IgnitionArguments [])

    let procs = getResourcesOfType (lsGraph ls1) :: [M0.Process]

    (ls2, _) <- run ls1 $ applyStateChanges $ (`stateSet` TrI.constTransition M0.PSOnline) <$> procs

    assertMsg "All processes should be online"
      $ length (connectedFrom Is M0.PSOnline (lsGraph ls2) :: [M0.Process]) ==
        length procs

    (ls3, _) <- run ls2 $ applyStateChanges $ (`stateSet` TrI.constTransition M0.PSStopping) <$> procs

    assertMsg "All processes should be stopping"
      $ length (connectedFrom Is M0.PSStopping (lsGraph ls3) :: [M0.Process]) ==
        length procs

testClusterLiveness :: (Typeable g, RGroup g) => Transport -> Proxy g -> TestTree
testClusterLiveness transport pg = testGroup "cluster-liveness"
  [ Tasty.testCase "on-new-cluster"
       $ genericTest (return ()) 
       $ Tasty.assertEqual "cluster is alive"
           ClusterLiveness{clPVers=True,clOngoingSNS=False, clHaveQuorum=True, clPrincipalRM=True}
  , Tasty.testCase "on-broken-confd-quorum-no-rm"
       $ genericTest (do 
           rg <- getLocalGraph
           let confds = nub [ ps | ps :: M0.Process <- getResourcesOfType rg 
                                 , srv <- connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_MGS
                                 , any (\s -> isConnected (s::M0.Service) Is M0.PrincipalRM rg)
                                       (connectedTo ps M0.IsParentOf rg)
                                 ]
           applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> confds
           )
       $ Tasty.assertEqual "cluster is alive"
           ClusterLiveness{clPVers=True,clOngoingSNS=False,clHaveQuorum=True, clPrincipalRM=False}
  , Tasty.testCase "on-broken-confd-quorum"
       $ genericTest (do 
           rg <- getLocalGraph
           let confds = nub [ ps | ps :: M0.Process <- getResourcesOfType rg 
                                 , srv <- connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_MGS
                                 , not $ any (\s -> isConnected (s::M0.Service) Is M0.PrincipalRM rg)
                                             (connectedTo ps M0.IsParentOf rg)
                                 ]
           applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> take 1 confds
           )
       $ Tasty.assertEqual "cluster is alive"
           ClusterLiveness{clPVers=True,clOngoingSNS=False,clHaveQuorum=True, clPrincipalRM=True}
  , Tasty.testCase "on-broken-confd-no-quorum"
       $ genericTest (do 
           rg <- getLocalGraph
           let confds = nub [ ps | ps :: M0.Process <- getResourcesOfType rg 
                                 , srv <- connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_MGS
                                 ]
           applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> take 3 confds
           )
       $ Tasty.assertEqual "cluster have no quorum"
            ClusterLiveness{clPVers=True,clOngoingSNS=False,clHaveQuorum=False,clPrincipalRM=False}
  -- , testCase "ongoing-sns" XXX: not yet implemented, I don't know the good way to test that
  --     without starting proper confd, and just inserting SNS info into the graph will be a fake
  --     test.
  , Tasty.testCase "on-ios-failure" 
       $ genericTest (do 
           rg <- getLocalGraph
           let ios = nub [ ps | ps :: M0.Process <- getResourcesOfType rg 
                                 , srv <- connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_IOS
                                 ]
           applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> take 1 ios
           )
       $ Tasty.assertEqual "pvers can be found"
            ClusterLiveness{clPVers=True,clOngoingSNS=False,clHaveQuorum=True,clPrincipalRM=True}
  , Tasty.testCase "on-many-ios" 
       $ genericTest (do 
           rg <- getLocalGraph
           let ios = nub [ ps | ps :: M0.Process <- getResourcesOfType rg 
                                 , srv <- connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_IOS
                                 ]
           applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> take 2 ios
           )
       $ Tasty.assertEqual "pvers can't be found"
            ClusterLiveness{clPVers=False,clOngoingSNS=False,clHaveQuorum=True,clPrincipalRM=True}
  ] where
    genericTest :: (PhaseM RC Int ()) -> (ClusterLiveness -> IO ()) -> IO ()
    genericTest configure test = rGroupTest transport pg $ \pid -> do
      me <- getSelfNode
      ls0 <- emptyLoopState pid (nullProcessId me)
      settings <- liftIO defaultInitialDataSettings
      iData' <- liftIO . initialData $ settings { _id_servers = 3, _id_drives = 4 }
      let iData = iData'{CI.id_m0_globals = (CI.id_m0_globals iData'){CI.m0_failure_set_gen=CI.Formulaic [[0,0,0,1,0]
                                                                                                         ,[0,0,0,0,1]
                                                                                                         ,[0,0,0,0,2]]}}
      (ls1, _) <- run ls0 $ do
         mapM_ goRack (CI.id_racks iData)
         filesystem <- initialiseConfInRG
         loadMeroGlobals (CI.id_m0_globals iData)
         loadMeroServers filesystem (CI.id_m0_servers iData)
         Just (Monolithic update) <- getCurrentGraphUpdateType
         modifyLocalGraph update
         RC.initialRule (IgnitionArguments [])
      let procs = getResourcesOfType (lsGraph ls1) :: [M0.Process]
      (ls2, _) <- run ls1 $ do
        applyStateChanges $ (`stateSet` TrI.constTransition M0.PSOnline) <$> procs
        _ <- pickPrincipalRM
        return ()
      (ls3, _) <- run ls2 $ configure
      box <- liftIO newEmptyMVar
      _ <- run ls3 $ do
        rg <- getLocalGraph
        liftIO . putMVar box =<< calculateClusterLiveness rg
      liftIO $ test =<< takeMVar box


run :: forall app g. (Application app, g ~ GlobalState app)
    => g
    -> PhaseM app Int ()
    -> Process (g, [(Buffer, Int)])
run ls = runPhase ls (0 :: Int) emptyFifoBuffer

runGet :: forall app g a. (Application app, g ~ GlobalState app)
       => g -> PhaseM app (Maybe a) a -> Process a
runGet = runPhaseGet

goRack :: forall l. CI.Rack
       -> PhaseM RC l ()
goRack (CI.Rack{..}) = let rack = Rack rack_idx in do
  registerRack rack
  mapM_ (goEnc rack) rack_enclosures
goEnc :: forall l. Rack
      -> CI.Enclosure
      -> PhaseM RC l ()
goEnc rack (CI.Enclosure{..}) = let
    enclosure = Enclosure enc_id
  in do
    registerEnclosure rack enclosure
    mapM_ (registerBMC enclosure) enc_bmc
    mapM_ (goHost enclosure) enc_hosts
goHost :: forall l. Enclosure
       -> CI.Host
       -> PhaseM RC l ()
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
