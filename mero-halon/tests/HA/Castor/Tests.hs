{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies    #-}
-- |
-- Module    : HA.Castor.Tests
-- Copyright : (C) 2015-2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- General Castor-related tests
module HA.Castor.Tests (tests) where

import           Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import           Control.Distributed.Process
  (Process, RemoteTable, liftIO, getSelfNode, unClosure)
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Internal.Types (nullProcessId)
import           Control.Distributed.Process.Node
import           Control.Monad (void)
import           Data.Bifunctor (first)
import           Data.Either (isRight, lefts)
import           Data.Foldable (for_)
import           Data.List (nub)
import           Data.Proxy
import qualified Data.Set as Set
import           Data.Typeable
import           System.Directory (removeFile)
import           System.Environment (getExecutablePath)
import           System.FilePath ((</>), joinPath, splitDirectories)
import           System.Process (callProcess)

import           HA.Multimap (MetaInfo, StoreChan, defaultMetaInfo)
import           HA.Multimap.Implementation (Multimap, fromList)
import           HA.Multimap.Process (startMultimap)
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Castor.Rules (goSite)
import           HA.RecoveryCoordinator.Castor.Cluster.Actions
import           HA.RecoveryCoordinator.Castor.Cluster.Events
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Mero.State (applyStateChanges, stateSet)
import qualified HA.RecoveryCoordinator.Mero.Transitions.Internal as TrI
import qualified HA.RecoveryCoordinator.RC.Rules as RC
import           HA.Replicator (RGroup(..))
import qualified HA.ResourceGraph as G
import           HA.Resources.Castor (Is(..))
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0
import           Helper.InitialData
import           Helper.RC
import           Mero.ConfC (ServiceType(CST_CONFD,CST_IOS))
import           Network.CEP (Application(..), Buffer, PhaseM, emptyFifoBuffer)
import           Network.CEP.Testing (runPhase)
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
  [ testSuccess "pool-versions" $ testPVers transport pg
  , testSuccess "apply-state-changes" $ testApplyStateChanges transport pg
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

testPVers :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testPVers transport pg = rGroupTest transport pg $ \pid -> do
    me <- getSelfNode
    ls <- emptyLoopState pid (nullProcessId me)
    settings <- liftIO defaultInitialDataSettings
    iData <- liftIO . initialData $ settings
      { _id_servers = 4
      , _id_drives = 4
      , _id_allowed_failures = formulas
      }
    (ls', _) <- run ls (initialDataLoad iData)
    let rg = lsGraph ls'
        pversPerPool =
          [ pvers
          | pool :: M0.Pool <- G.connectedTo (M0.getM0Root rg) M0.IsParentOf rg
          , M0.fid pool /= M0.rt_mdpool (M0.getM0Root rg)
          , let pvers :: [M0.PVer] = G.connectedTo pool M0.IsParentOf rg
          ]
    for_ pversPerPool $ \pvers -> do
        let actual = filter (isRight . M0.v_data) pvers :: [M0.PVer]
            formulaic = lefts (map M0.v_data pvers)     :: [M0.PVerFormulaic]
        assertEqual "There should be exactly one actual PVer for Pool" 1
            (length actual)
        assertEqual "Each formula should be presented" (length formulas)
            (length formulaic)
        for_ formulaic $ \pvf ->
            assertEqual "Base fid should be equal to that of actual pver"
                (M0.vf_base pvf) (M0.v_fid $ head actual)
        assertEqual "All formulas should be presented"
            (Set.fromList $ map CI.failuresToList formulas)
            (Set.fromList $ map M0.vf_allowance formulaic)
        let vf_ids = Set.fromList $ map M0.vf_id formulaic
        liftIO . Tasty.assertBool "All vf_ids should be unique" $
            Set.size vf_ids == length formulas
  where
    assertEqual preface expected = liftIO . Tasty.assertEqual preface expected
    formulas = [CI.Failures 0 0 0 0 1, CI.Failures 0 0 0 1 1]

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
                                 , M0.s_type srv == CST_CONFD
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
                                 , M0.s_type srv == CST_CONFD
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
                                 , M0.s_type srv == CST_CONFD
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
                                 , M0.s_type srv == CST_IOS
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
                                 , M0.s_type srv == CST_IOS
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
      iData <- liftIO . initialData $ settings
        { _id_servers = 3
        , _id_drives = 4
        , _id_allowed_failures = [ CI.Failures 0 0 0 1 0
                                 , CI.Failures 0 0 0 0 1
                                 , CI.Failures 0 0 0 0 2
                                 ]
        }
      (ls1, _) <- run ls0 $ do
        initialDataLoad iData
        RC.initialRule (IgnitionArguments [])
      let procs = G.getResourcesOfType (lsGraph ls1) :: [M0.Process]
      (ls2, _) <- run ls1 $ do
        void . applyStateChanges $
          map (`stateSet` TrI.constTransition M0.PSOnline) procs
        _ <- pickPrincipalRM
        return ()
      (ls3, _) <- run ls2 configure
      box <- liftIO newEmptyMVar
      _ <- run ls3 $ do
        rg <- getGraph
        liftIO . putMVar box =<< calculateClusterLiveness rg
      liftIO $ test =<< takeMVar box

initialDataLoad :: CI.InitialData -> PhaseM RC l ()
initialDataLoad CI.InitialData{..} = do
    mapM_ goSite id_sites
    initialiseConfInRG
    loadMeroGlobals id_m0_globals
    loadMeroServers id_m0_servers
    loadMeroPools id_pools >>= loadMeroProfiles id_profiles

run :: forall app g. (Application app, g ~ GlobalState app)
    => g
    -> PhaseM app Int ()
    -> Process (g, [(Buffer, Int)])
run ls = runPhase ls (0 :: Int) emptyFifoBuffer
