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
import           Data.List (intercalate, partition, nub)
import           Data.Maybe (catMaybes, maybeToList)
import           Data.Proxy
import qualified Data.Set as Set
import qualified Data.Text as T
import           Data.Typeable
import           System.Directory (removeFile)
import           System.Environment (getExecutablePath)
import           System.FilePath ((</>), joinPath, splitDirectories)
import           System.Process (callProcess)

import           HA.Multimap
import           HA.Multimap.Implementation (Multimap, fromList)
import           HA.Multimap.Process (startMultimap)
import           HA.RecoveryCoordinator.Actions.Mero
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
import           HA.Resources (Cluster(..), Has(..))
import           HA.Resources.Castor (Is(..))
import qualified HA.Resources.Castor as R
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
  ++ [testSuccess "parse-initial-data" testParseInitialData]

testParseInitialData :: IO ()
testParseInitialData = do
    exe <- (</> "scripts" </> "h0fabricate") <$> getH0SrcDir
    withTmpDirectory $ do
        callProcess exe ["--output-directory", "."]
        let files@(facts:meroRoles:halonRoles:[]) =
              ["h0fabricated-" ++ name ++ ".yaml"
              | name <- ["facts", "roles_mero", "roles_halon"]]
        res <- CI.parseInitialData facts meroRoles halonRoles
        for_ files removeFile
        either Tasty.assertFailure pure (check res)
  where
    getH0SrcDir = joinPath . reverse . drop 8 . reverse . splitDirectories
                  <$> getExecutablePath
    check e = do
        e' <- first show e
        void $ first (intercalate "\n") (uncurry CI.resolveHalonRoles e')

fsSize :: (a, Set.Set b) -> Int
fsSize (_, a) = Set.size a

testFailureSets :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testFailureSets transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    settings <- liftIO defaultInitialDataSettings
    iData <- liftIO . initialData $ settings
               { _id_drives = 8
               , _id_globals = defaultGlobals { CI.m0_data_units_XXX0 = 4 } }
    (ls', _) <- run ls $ do
      mapM_ goRack (CI.id_racks_XXX0 iData)
      filesystem <- initialiseConfInRG_XXX3
      loadMeroGlobals (CI.id_m0_globals_XXX0 iData)
      loadMeroServers filesystem (CI.id_m0_servers_XXX0 iData)
    -- 8 disks, tolerating one disk failure at a time
    let g = lsGraph ls'
        failureSets = generateFailureSets 1 0 0 g (CI.id_m0_globals_XXX0 iData)
    assertMsg "Number of failure sets (100)" $ length failureSets == 9
    assertMsg "Smallest failure set is empty (100)"
      $ fsSize (head failureSets) == 0

    -- 8 disks, two failures at a time
    let failureSets2 = generateFailureSets 2 0 0 g (CI.id_m0_globals_XXX0 iData)
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
      mapM_ goRack (CI.id_racks_XXX0 iData)
      filesystem <- initialiseConfInRG_XXX3
      loadMeroGlobals (CI.id_m0_globals_XXX0 iData)
      loadMeroServers filesystem (CI.id_m0_servers_XXX0 iData)
    -- 16 disks, tolerating one disk failure at a time
    let g = lsGraph ls'
        failureSets = generateFailureSets 1 0 0 g (CI.id_m0_globals_XXX0 iData)
    assertMsg "Number of failure sets (100)" $ length failureSets == 17
    assertMsg "Smallest failure set is empty (100)"
      $ fsSize (head failureSets) == 0

    -- 16 disks, two failures at a time
    let failureSets2 = generateFailureSets 2 0 0 g (CI.id_m0_globals_XXX0 iData)
    assertMsg "Number of failure sets (200)" $ length failureSets2 == 137
    assertMsg "Smallest failure set is empty (200)"
      $ fsSize (head failureSets2) == 0
    assertMsg "Next smallest failure set has one disk (200)"
      $ fsSize (failureSets2 !! 1) == 1

    let failureSets010 = generateFailureSets 0 1 0 g (CI.id_m0_globals_XXX0 iData)
    assertMsg "Number of failure sets (010)" $ length failureSets010 == 5
    assertMsg "Smallest failure set is empty (010)"
      $ fsSize (head failureSets010) == 0
    assertMsg "Next smallest failure set has 4 disks and one controller (010)"
      $ fsSize (failureSets010 !! 1) == 5

    let failureSets110 = generateFailureSets 1 1 0 g (CI.id_m0_globals_XXX0 iData)
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
               , _id_globals = defaultGlobals { CI.m0_failure_set_gen_XXX0 = CI.Formulaic sets} }
    (ls', _) <- run ls $ do
      mapM_ goRack (CI.id_racks_XXX0 iData)
      filesystem <- initialiseConfInRG_XXX3
      loadMeroGlobals (CI.id_m0_globals_XXX0 iData)
      loadMeroServers filesystem (CI.id_m0_servers_XXX0 iData)
      Just (Monolithic update) <- getCurrentGraphUpdateType
      modifyLocalGraph update

    let g = lsGraph ls'

    let ppvers = [(pool, pvers) | Just (root :: M0.Root) <- [G.connectedTo Cluster Has g]
                                , Just (profile :: M0.Profile_XXX3) <- [G.connectedTo root M0.IsParentOf g]
                                , fs :: M0.Filesystem <- G.connectedTo profile M0.IsParentOf g
                                , pool :: M0.Pool     <- G.connectedTo fs M0.IsParentOf g
                                , let pvers :: [M0.PVer] = G.connectedTo pool M0.IsParentOf g
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
      mapM_ goRack (CI.id_racks_XXX0 iData)
      filesystem <- initialiseConfInRG_XXX3
      loadMeroGlobals (CI.id_m0_globals_XXX0 iData)
      loadMeroServers filesystem (CI.id_m0_servers_XXX0 iData)
      rg <- getLocalGraph
      let Iterative update = simpleUpdate 0 1 0
      let Just updateGraph = update rg
      rg' <- updateGraph return
      putLocalGraph rg'
    -- Verify that everything is set up correctly
    Just fs <- runGet ls' getFilesystem
    let mdpool = M0.Pool (M0.f_mdpool_fid fs)
    assertMsg "MDPool is stored in RG"
      $ G.memberResource mdpool (lsGraph ls')
    mdpool_byFid <- runGet ls' $ lookupConfObjByFid (M0.f_mdpool_fid fs)
    assertMsg "MDPool is findable by Fid"
      $ mdpool_byFid == Just mdpool

    -- Get the non metadata pool
    [pool] <- runGet ls' $ Pool.getNonMD <$> getLocalGraph

    -- We have 4 disks in 4 enclosures.
    hosts <- runGet ls' $ findHosts ".*"
    let g = lsGraph ls'
        pvers = G.connectedTo pool M0.IsParentOf g :: [M0.PVer]
        racks = G.connectedTo fs M0.IsParentOf g :: [M0.Rack]
        encls = join $ fmap (\r -> G.connectedTo r M0.IsParentOf g :: [M0.Enclosure]) racks
        ctrls = join $ fmap (\r -> G.connectedTo r M0.IsParentOf g :: [M0.Controller]) encls
        disks = join $ fmap (\r -> G.connectedTo r M0.IsParentOf g :: [M0.Disk]) ctrls
        enc   = catMaybes $ fmap (\r -> G.connectedFrom Has r g :: Maybe R.Enclosure_XXX1) hosts
        sdevs = join $ fmap (\r -> [ d | s <- G.connectedTo r Has g :: [R.Slot_XXX1]
                                       , d <- maybeToList (G.connectedFrom Has s g :: Maybe R.StorageDevice_XXX1) ])
                            enc
        disksByHost = catMaybes $ fmap (\r -> G.connectedFrom M0.At r g :: Maybe M0.Disk) sdevs

        disk1 = head disks
        dvers1 = G.connectedTo disk1 M0.IsRealOf g :: [M0.DiskV]

    assertMsg "Number of pvers" $ length pvers == 5
    assertMsg "Number of racks" $ length racks == 1
    assertMsg "Number of enclosures" $ length encls == 4
    assertMsg "Number of controllers" $ length ctrls == 4
    assertMsg "Number of storage devices" $ length sdevs == 16
    assertMsg "Number of disks (reached by host)" $ length disksByHost == 16
    assertMsg "Number of disks" $ length disks == 16
    assertMsg "Number of disk versions" $ length dvers1 == 4
    forM_ (G.getResourcesOfType g :: [M0.PVer]) $ \pver -> do
      let PDClustAttr { pa_N = paN
                      , pa_K = paK
                      , pa_P = paP
                      } = M0.v_attrs $ (\(M0.PVer _ a) -> a) $ pver
      assertMsg "N in PVer" $ CI.m0_data_units_XXX0 (CI.id_m0_globals_XXX0 iData) == paN
      assertMsg "K in PVer" $ CI.m0_parity_units_XXX0 (CI.id_m0_globals_XXX0 iData) == paK
      let dver = [ diskv | rackv <- G.connectedTo  pver M0.IsParentOf g :: [M0.RackV]
                         , enclv <- G.connectedTo rackv M0.IsParentOf g :: [M0.EnclosureV]
                         , cntrv <- G.connectedTo enclv M0.IsParentOf g :: [M0.ControllerV]
                         , diskv <- G.connectedTo cntrv M0.IsParentOf g :: [M0.DiskV]]
      liftIO $ Tasty.assertEqual "P in PVer" paP $ fromIntegral (length dver)

-- | Test that applying state changes works
testApplyStateChanges :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testApplyStateChanges transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls0 <- emptyLoopState pid (nullProcessId me)
    settings <- liftIO defaultInitialDataSettings
    iData <- liftIO . initialData $ settings { _id_servers = 4, _id_drives = 4 }
    (ls1, _) <- run ls0 $ do
      mapM_ goRack (CI.id_racks_XXX0 iData)
      filesystem <- initialiseConfInRG_XXX3
      loadMeroGlobals (CI.id_m0_globals_XXX0 iData)
      loadMeroServers filesystem (CI.id_m0_servers_XXX0 iData)
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
           rg <- getLocalGraph
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
           rg <- getLocalGraph
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
           rg <- getLocalGraph
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
           rg <- getLocalGraph
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
           rg <- getLocalGraph
           let ios = nub [ ps | ps :: M0.Process <- G.getResourcesOfType rg
                                 , srv <- G.connectedTo ps M0.IsParentOf rg
                                 , M0.s_type srv == ConfC.CST_IOS
                                 ]
           void . applyStateChanges $ (`stateSet` TrI.constTransition (M0.PSFailed "test")) <$> take 2 ios
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
      let iData = iData'{CI.id_m0_globals_XXX0 = (CI.id_m0_globals_XXX0 iData'){CI.m0_failure_set_gen_XXX0=CI.Formulaic [[0,0,0,1,0]
                                                                                                         ,[0,0,0,0,1]
                                                                                                         ,[0,0,0,0,2]]}}
      (ls1, _) <- run ls0 $ do
         mapM_ goRack (CI.id_racks_XXX0 iData)
         filesystem <- initialiseConfInRG_XXX3
         loadMeroGlobals (CI.id_m0_globals_XXX0 iData)
         loadMeroServers filesystem (CI.id_m0_servers_XXX0 iData)
         Just (Monolithic update) <- getCurrentGraphUpdateType
         modifyLocalGraph update
         RC.initialRule (IgnitionArguments [])
      let procs = G.getResourcesOfType (lsGraph ls1) :: [M0.Process]
      (ls2, _) <- run ls1 $ do
        void . applyStateChanges $ (`stateSet` TrI.constTransition M0.PSOnline) <$> procs
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

goRack :: forall l. CI.Rack_XXX0 -> PhaseM RC l ()
goRack CI.Rack_XXX0{..} = let rack = R.Rack_XXX1 rack_idx_XXX0 in do
  registerRack_XXX3 rack
  mapM_ (goEnc rack) rack_enclosures_XXX0

goEnc :: forall l. R.Rack_XXX1 -> CI.Enclosure_XXX0 -> PhaseM RC l ()
goEnc rack (CI.Enclosure_XXX0{..}) = let
    enclosure = R.Enclosure_XXX1 enc_id_XXX0
  in do
    registerEnclosure rack enclosure
    mapM_ (registerBMC enclosure) enc_bmc_XXX0
    mapM_ (goHost enclosure) enc_hosts_XXX0

goHost :: forall l. R.Enclosure_XXX1 -> CI.Host_XXX0 -> PhaseM RC l ()
goHost enc CI.Host_XXX0{..} = let
    host = R.Host_XXX1 $ T.unpack h_fqdn_XXX0
  in do
    registerHost host
    locateHostInEnclosure host enc
