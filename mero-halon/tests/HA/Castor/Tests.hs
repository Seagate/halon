{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}
-- |
-- Module    : HA.Castor.Tests
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- General Castor-related tests
module HA.Castor.Tests (tests) where

import           Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import           Control.Distributed.Process
  (Process, RemoteTable, liftIO, getSelfNode, unClosure)
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Internal.Types (nullProcessId)
import           Control.Distributed.Process.Node
import           Control.Monad (forM_, join, unless, void)
import           Data.Bifunctor (first)
import           Data.Foldable (for_)
import           Data.Either (isRight, lefts)
import           Data.List (nub)
import           Data.Maybe (catMaybes, maybeToList)
import           Data.Proxy
import qualified Data.Set as Set
import           Data.Typeable
import           System.Directory (removeFile)
import           System.Environment (getExecutablePath)
import           System.FilePath ((</>), joinPath, splitDirectories)
import           System.Process (callProcess)

import           HA.Multimap
import           HA.Multimap.Implementation (Multimap, fromList)
import           HA.Multimap.Process (startMultimap)
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Castor.Rules (goSite)
import           HA.RecoveryCoordinator.Castor.Cluster.Actions
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import qualified HA.RecoveryCoordinator.Castor.Pool.Actions as Pool
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Mero.Actions.Failure
import           HA.RecoveryCoordinator.Mero.Failure.Simple
import           HA.RecoveryCoordinator.Mero.State (applyStateChanges, stateSet)
import qualified HA.RecoveryCoordinator.Mero.Transitions.Internal as TrI
import qualified HA.RecoveryCoordinator.RC.Rules as RC
import           HA.Replicator (RGroup(..))
import qualified HA.ResourceGraph as G
import           HA.Resources (Has(..))
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Helper.InitialData
import           Helper.RC
import           Mero.ConfC (PDClustAttr(..))
import qualified Mero.ConfC as ConfC
import           Network.CEP (Application(..), Buffer, PhaseM, emptyFifoBuffer)
import           Network.CEP.Testing (runPhase, runPhaseGet)
import           Network.Transport (Transport)
import           RemoteTables (remoteTable)
import           Test.Framework
import qualified Test.Tasty.HUnit as Tasty
import           TestRunner

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
  ++
  [ testSuccess "parse-initial-data" testParseInitialData]

testParseInitialData :: IO ()
testParseInitialData = do
    exe <- (</> "scripts" </> "h0fabricate") <$> getH0SrcDir
    withTmpDirectory $ do
        callProcess exe ["--out-dir", "."]
        let files@(facts:meroRoles:halonRoles:[]) =
              ["h0fabricated-" ++ name ++ ".yaml"
              | name <- ["facts", "roles_mero", "roles_halon"]]
        ev <- first show <$> CI.parseInitialData facts meroRoles halonRoles
        for_ files removeFile
        either Tasty.assertFailure pure (void . check =<< ev)
  where
    getH0SrcDir = joinPath . takeWhile (/= "mero-halon") . splitDirectories
        <$> getExecutablePath

    check (initData, halonRolesObj) =
        traverse (CI.mkHalonRoles halonRolesObj . CI._hs_roles)
            [ h0params | site <- CI.id_sites initData
                       , rack <- CI.site_racks site
                       , encl <- CI.rack_enclosures rack
                       , host <- CI.enc_hosts encl
                       , Just h0params <- [CI.h_halon host] ]

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
    (ls', _) <- run ls $ initialDataLoad iData
    -- 8 disks, tolerating one disk failure at a time
    let rg = lsGraph ls'
        failureSets = generateFailureSets 1 0 0 rg (CI.id_m0_globals iData)
    assertMsg "Number of failure sets (100)" $ length failureSets == 9
    assertMsg "Smallest failure set is empty (100)"
      $ fsSize (head failureSets) == 0

    -- 8 disks, two failures at a time
    let failureSets2 = generateFailureSets 2 0 0 rg (CI.id_m0_globals iData)
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
    (ls', _) <- run ls $ initialDataLoad iData
    -- 16 disks, tolerating one disk failure at a time
    let rg = lsGraph ls'
        failureSets = generateFailureSets 1 0 0 rg (CI.id_m0_globals iData)
    assertMsg "Number of failure sets (100)" $ length failureSets == 17
    assertMsg "Smallest failure set is empty (100)"
      $ fsSize (head failureSets) == 0

    -- 16 disks, two failures at a time
    let failureSets2 = generateFailureSets 2 0 0 rg (CI.id_m0_globals iData)
    assertMsg "Number of failure sets (200)" $ length failureSets2 == 137
    assertMsg "Smallest failure set is empty (200)"
      $ fsSize (head failureSets2) == 0
    assertMsg "Next smallest failure set has one disk (200)"
      $ fsSize (failureSets2 !! 1) == 1

    let failureSets010 = generateFailureSets 0 1 0 rg (CI.id_m0_globals iData)
    assertMsg "Number of failure sets (010)" $ length failureSets010 == 5
    assertMsg "Smallest failure set is empty (010)"
      $ fsSize (head failureSets010) == 0
    assertMsg "Next smallest failure set has 4 disks and one controller (010)"
      $ fsSize (failureSets010 !! 1) == 5

    let failureSets110 = generateFailureSets 1 1 0 rg (CI.id_m0_globals iData)
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
               , _id_globals = defaultGlobals {CI.m0_failure_set_gen = CI.Formulaic sets}
               }
    (ls', _) <- run ls $ do
      initialDataLoad iData
      Just (Monolithic update) <- getCurrentGraphUpdateType
      modifyGraphM update

    let rg = lsGraph ls'
        ppvers = [ (pool, pvers)
                 | pool :: M0.Pool <- G.connectedTo (M0.getM0Root rg) M0.IsParentOf rg
                 , let pvers :: [M0.PVer] = G.connectedTo pool M0.IsParentOf rg
                 ]
    for_ ppvers $ \(_, pvers) -> do
      unless (null pvers) $ do -- skip metadata pool
        let actual@[M0.PVer fid _] = filter (isRight . M0.v_data) pvers
            formulaic = lefts $ map M0.v_data pvers
        liftIO $ Tasty.assertEqual "There should be only one actual PVer for Pool" 1 (length actual)
        liftIO $ Tasty.assertEqual "Each formula should be presented" (length sets) (length formulaic)
        for_ formulaic $ \f ->
          liftIO $ Tasty.assertEqual "base fid should be equal to actual pver" fid (M0.vf_base f)
        let sets2 = Set.fromList $ map M0.vf_allowance formulaic
        liftIO $ Tasty.assertEqual "all formulas should be presented" (Set.fromList sets) sets2
        let ids = Set.fromList $ map M0.vf_id formulaic
        liftIO $ Tasty.assertBool "all ids should be unique" (Set.size ids == length sets)
  where
    sets = [[0,0,0,0,1], [0,0,0,1,1]]

-- | Test that failure domain logic works correctly when we are
testControllerFailureDomain :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testControllerFailureDomain transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    settings <- liftIO defaultInitialDataSettings
    iData <- liftIO . initialData $ settings { _id_servers = 4, _id_drives = 4 }
    (ls', _) <- run ls $ do
      initialDataLoad iData
      rg <- getGraph
      let Iterative update = simpleUpdate 0 1 0
          Just updateGraph = update rg
      rg' <- updateGraph return
      putGraph rg'
    -- Verify that everything is set up correctly
    Just root <- runGet ls' getRoot
    let mdpool = M0.Pool (M0.rt_mdpool root)
    assertMsg "MDPool is stored in RG"
      $ G.memberResource mdpool (lsGraph ls')
    mdpool_byFid <- runGet ls' $ lookupConfObjByFid (M0.rt_mdpool root)
    assertMsg "MDPool is findable by Fid"
      $ mdpool_byFid == Just mdpool

    -- Get the non metadata pool
    [pool] <- runGet ls' $ Pool.getNonMD <$> getGraph

    -- We have 4 disks in 4 enclosures.
    hosts <- runGet ls' $ findHosts ".*"
    let rg = lsGraph ls'
        pvers = G.connectedTo pool M0.IsParentOf rg :: [M0.PVer]
        sites = G.connectedTo root M0.IsParentOf rg :: [M0.Site]
        racks = join $ fmap (\s -> G.connectedTo s M0.IsParentOf rg :: [M0.Rack]) sites
        encls = join $ fmap (\r -> G.connectedTo r M0.IsParentOf rg :: [M0.Enclosure]) racks
        ctrls = join $ fmap (\e -> G.connectedTo e M0.IsParentOf rg :: [M0.Controller]) encls
        disks = join $ fmap (\c -> G.connectedTo c M0.IsParentOf rg :: [M0.Disk]) ctrls
        enclsH = catMaybes $ fmap (\h -> G.connectedFrom Has h rg :: Maybe Enclosure) hosts
        sdevs = join $ fmap (\e -> [ d | s <- G.connectedTo e Has rg :: [Slot]
                                       , d <- maybeToList (G.connectedFrom Has s rg :: Maybe StorageDevice) ])
                            enclsH
        disksByHost = catMaybes $ fmap (\s -> G.connectedFrom M0.At s rg :: Maybe M0.Disk) sdevs

        diskvs1 = G.connectedTo (head disks) M0.IsRealOf rg :: [M0.DiskV]

    assertMsg "Number of pvers" $ length pvers == 5
    assertMsg "Number of sites" $ length sites == 1
    assertMsg "Number of racks" $ length racks == 1
    assertMsg "Number of enclosures" $ length encls == 4
    assertMsg "Number of controllers" $ length ctrls == 4
    assertMsg "Number of storage devices" $ length sdevs == 16
    assertMsg "Number of disks (reached by host)" $ length disksByHost == 16
    assertMsg "Number of disks" $ length disks == 16
    assertMsg "Number of disk versions" $ length diskvs1 == 4
    forM_ (G.getResourcesOfType rg :: [M0.PVer]) $ \pver -> do
      let Right pva = M0.v_data pver
          attrs = M0.va_attrs pva
          globs = CI.id_m0_globals iData
      assertMsg "N in PVer" $ CI.m0_data_units globs == _pa_N attrs
      assertMsg "K in PVer" $ CI.m0_parity_units globs == _pa_K attrs
      let nr_diskvs = length
            [ diskv
            | sitev :: M0.SiteV <- G.connectedTo pver M0.IsParentOf rg
            , rackv :: M0.RackV <- G.connectedTo sitev M0.IsParentOf rg
            , enclv :: M0.EnclosureV <- G.connectedTo rackv M0.IsParentOf rg
            , cntrv :: M0.ControllerV <- G.connectedTo enclv M0.IsParentOf rg
            , diskv :: M0.DiskV <- G.connectedTo cntrv M0.IsParentOf rg
            ]
      liftIO $ Tasty.assertEqual "P in PVer" (_pa_P attrs) (fromIntegral nr_diskvs)

-- | Test that applying state changes works
testApplyStateChanges :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testApplyStateChanges transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls0 <- emptyLoopState pid (nullProcessId me)
    settings <- liftIO defaultInitialDataSettings
    iData <- liftIO . initialData $ settings { _id_servers = 4, _id_drives = 4 }
    (ls1, _) <- run ls0 $ do
      initialDataLoad iData
      RC.initialRule (IgnitionArguments [])

    let procs = G.getResourcesOfType (lsGraph ls1) :: [M0.Process]
    (ls2, _) <- run ls1 $ void $ applyStateChanges $ (`stateSet` TrI.constTransition M0.PSOnline) <$> procs

    assertMsg "All processes should be online"
      $ length (G.connectedFrom Is M0.PSOnline (lsGraph ls2) :: [M0.Process]) ==
        length procs

    (ls3, _) <- run ls2 $ void $ applyStateChanges $ (`stateSet` TrI.constTransition M0.PSStopping) <$> procs

    assertMsg "All processes should be stopping"
      $ length (G.connectedFrom Is M0.PSStopping (lsGraph ls3) :: [M0.Process]) ==
        length procs

testClusterLiveness :: (Typeable g, RGroup g) => Transport -> Proxy g -> TestTree
testClusterLiveness transport pg = testGroup "cluster-liveness"
  [ Tasty.testCase "on-new-cluster"
       $ genericTest (return ())
       $ Tasty.assertEqual "cluster is alive"
           ClusterLiveness{clPVers=True,clOngoingSNS=False, clHaveQuorum=True, clPrincipalRM=True}
  , Tasty.testCase "on-broken-confd-quorum-no-rm"
       $ genericTest (do
           rg <- getGraph
           let confds = nub [ ps | ps :: M0.Process <- G.getResourcesOfType rg
                                 , srv <- G.connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_CONFD
                                 , any (\s -> G.isConnected (s::M0.Service) Is M0.PrincipalRM rg)
                                       (G.connectedTo ps M0.IsParentOf rg)
                                 ]
           void . applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> confds
           )
       $ Tasty.assertEqual "cluster is alive"
           ClusterLiveness{clPVers=True,clOngoingSNS=False,clHaveQuorum=True, clPrincipalRM=False}
  , Tasty.testCase "on-broken-confd-quorum"
       $ genericTest (do
           rg <- getGraph
           let confds = nub [ ps | ps :: M0.Process <- G.getResourcesOfType rg
                                 , srv <- G.connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_CONFD
                                 , not $ any (\s -> G.isConnected (s::M0.Service) Is M0.PrincipalRM rg)
                                             (G.connectedTo ps M0.IsParentOf rg)
                                 ]
           void . applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> take 1 confds
           )
       $ Tasty.assertEqual "cluster is alive"
           ClusterLiveness{clPVers=True,clOngoingSNS=False,clHaveQuorum=True, clPrincipalRM=True}
  , Tasty.testCase "on-broken-confd-no-quorum"
       $ genericTest (do
           rg <- getGraph
           let confds = nub [ ps | ps :: M0.Process <- G.getResourcesOfType rg
                                 , srv <- G.connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_CONFD
                                 ]
           void . applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> take 3 confds
           )
       $ Tasty.assertEqual "cluster have no quorum"
            ClusterLiveness{clPVers=True,clOngoingSNS=False,clHaveQuorum=False,clPrincipalRM=False}
  -- , testCase "ongoing-sns" XXX: not yet implemented, I don't know the good way to test that
  --     without starting proper confd, and just inserting SNS info into the graph will be a fake
  --     test.
  , Tasty.testCase "on-ios-failure"
       $ genericTest (do
           rg <- getGraph
           let ios = nub [ ps | ps :: M0.Process <- G.getResourcesOfType rg
                                 , srv <- G.connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_IOS
                                 ]
           void . applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> take 1 ios
           )
       $ Tasty.assertEqual "pvers can be found"
            ClusterLiveness{clPVers=True,clOngoingSNS=False,clHaveQuorum=True,clPrincipalRM=True}
  , Tasty.testCase "on-many-ios"
       $ genericTest (do
           rg <- getGraph
           let ios = nub [ ps | ps :: M0.Process <- G.getResourcesOfType rg
                                 , srv <- G.connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_IOS
                                 ]
           void . applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> take 2 ios
           )
       $ Tasty.assertEqual "pvers can't be found"
            ClusterLiveness{clPVers=False,clOngoingSNS=False,clHaveQuorum=True,clPrincipalRM=True}
  ] where
    genericTest :: PhaseM RC Int () -> (ClusterLiveness -> IO ()) -> IO ()
    genericTest configure test = rGroupTest transport pg $ \pid -> do
      me <- getSelfNode
      ls0 <- emptyLoopState pid (nullProcessId me)
      settings <- liftIO defaultInitialDataSettings
      iData' <- liftIO . initialData $ settings { _id_servers = 3, _id_drives = 4 }
      let iData = iData'{CI.id_m0_globals = (CI.id_m0_globals iData'){CI.m0_failure_set_gen=CI.Formulaic [[0,0,0,1,0]
                                                                                                         ,[0,0,0,0,1]
                                                                                                         ,[0,0,0,0,2]]}}
      (ls1, _) <- run ls0 $ do
         initialDataLoad iData
         Just (Monolithic update) <- getCurrentGraphUpdateType
         modifyGraphM update
         RC.initialRule (IgnitionArguments [])
      let procs = G.getResourcesOfType (lsGraph ls1) :: [M0.Process]
      (ls2, _) <- run ls1 $ do
        void . applyStateChanges $ (`stateSet` TrI.constTransition M0.PSOnline) <$> procs
        _ <- pickPrincipalRM
        return ()
      (ls3, _) <- run ls2 $ configure
      box <- liftIO newEmptyMVar
      _ <- run ls3 $ do
        rg <- getGraph
        liftIO . putMVar box =<< calculateClusterLiveness rg
      liftIO $ test =<< takeMVar box

initialDataLoad :: CI.InitialData -> PhaseM RC l ()
initialDataLoad CI.InitialData{..} = do
    mapM_ goSite id_sites
    _filesystem <- initialiseConfInRG
    loadMeroGlobals id_m0_globals
    loadMeroServers id_m0_servers

run :: forall app g. (Application app, g ~ GlobalState app)
    => g
    -> PhaseM app Int ()
    -> Process (g, [(Buffer, Int)])
run ls = runPhase ls (0 :: Int) emptyFifoBuffer

runGet :: forall app g a. (Application app, g ~ GlobalState app)
       => g -> PhaseM app (Maybe a) a -> Process a
runGet = runPhaseGet
