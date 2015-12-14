{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
module HA.RecoveryCoordinator.SSPL.Tests
  ( utTests
  ) where

import Control.Distributed.Process.Closure
import Control.Exception (SomeException)

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set

import Network.Transport (Transport)
import Network.CEP
import Network.CEP.Testing (runPhase)

import HA.Multimap.Implementation (Multimap, fromList)
import HA.Multimap.Process (multimap)
import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Mero
import HA.RecoveryCoordinator.Events.Drive
import HA.Replicator (RGroup(..))
#ifdef USE_MOCK_REPLICATOR
import HA.Replicator.Mock (MC_RG)
#else
import HA.Replicator.Log (MC_RG)
#endif
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import HA.ResourceGraph hiding (__remoteTable)
import HA.Services.SSPL
import SSPL.Bindings
import Helper.SSPL

import Mero.ConfC (ServiceParams(..), ServiceType(..))

import RemoteTables (remoteTable)
import TestRunner
import Data.Binary
import Data.Typeable
import Data.Foldable
import GHC.Generics

import Data.UUID.V4 (nextRandom)
import Data.Text (Text)

import Test.Tasty
import Test.Tasty.HUnit (assertEqual)
import Test.Framework
import System.IO
import Control.Distributed.Process

data GetGraph = GetGraph ProcessId deriving (Eq,Show, Typeable, Generic)

instance Binary GetGraph

mmSDict :: SerializableDict Multimap
mmSDict = SerializableDict

remotable
  [ 'mmSDict ]

emptyLoopState :: ProcessId -> ProcessId -> Process LoopState
emptyLoopState mmpid pid = do
  g <- getGraph mmpid
  return $ LoopState g Map.empty mmpid pid Set.empty

myRemoteTable :: RemoteTable
myRemoteTable = HA.RecoveryCoordinator.SSPL.Tests.__remoteTable remoteTable

rGroupTest :: Transport -> (ProcessId -> Process ()) -> IO ()
rGroupTest transport p =
  tryRunProcessLocal transport myRemoteTable $ do
    nid <- getSelfNode
    rGroup <- newRGroup $(mkStatic 'mmSDict) 20 1000000 [nid] (fromList [])
                >>= unClosure
                >>= (`asTypeOf` return (undefined :: MC_RG Multimap))
    mmpid <- spawnLocal $ catch (multimap rGroup) $
      (\e -> liftIO $ hPutStrLn stderr (show (e :: SomeException)))
    p mmpid

-- List of unit tests
utTests :: Transport -> TestTree
utTests transport = testGroup "Service-SSPL"
   [ testGroup "hpi-requests"
       [ testSuccess "hpi request with existing WWN"
       $ testHpiExistingWWN transport
       , testSuccess "hpi request with new resource"
       $ testHpiNewWWN transport
       , testSuccess "hpi request with updated WWN"
       $ testHpiUpdatedWWN transport
       ]
   , testSuccess "drive-manager-works"
   $ testDMRequest transport
   ]

dmRequest :: Text -> Text -> Int -> SensorResponseMessageSensor_response_typeDisk_status_drivemanager
dmRequest status _serial num = mkResponseDriveManager "enclosure1" "serial1" (fromIntegral num) status

mkHpiTest :: (ProcessId -> Definitions LoopState b)
          -> (ProcessId -> Process ())
          -> Transport
          -> IO ()
mkHpiTest mkTestRule test transport = rGroupTest transport $ \pid -> do
    self <- getSelfPid
    ls <- emptyLoopState pid self
    (ls',_)  <- run ls $ do
            mapM_ goRack (CI.id_racks initialData)
            filesystem <- initialiseConfInRG
            loadMeroGlobals (CI.id_m0_globals initialData)
            loadMeroServers filesystem (CI.id_m0_servers initialData)
    let testRule = mkTestRule self
    rc <- spawnLocal $ execute ls' (testRule >> ssplRules)
    test rc

testHpiExistingWWN :: Transport -> IO ()
testHpiExistingWWN = mkHpiTest rules test
  where
    rules self = define "check-test" $ do
      ph0 <- phaseHandle "init"
      ph1 <- phaseHandle "test"
      setPhase ph0 $ \() -> do
        g <- getLocalGraph
        Network.CEP.put Local (Just g)
        continue ph1
      setPhase ph1 $ \() -> do
        Just g <- Network.CEP.get Local
        g' <- getLocalGraph
        liftProcess $ usend self (getGraphResources g == getGraphResources g')
      start ph0 Nothing
    test rc = do
      me <- getSelfNode
      usend rc ()  -- Prepare graph test
      let request = mkResponseHPI "primus.example.com" 1 "loop1" "wwn1"
      uuid <- liftIO $ nextRandom
      usend rc $ HAEvent uuid (me, request) [] -- send request
      receiveWait [ matchIf (\u -> u == uuid) (\_ -> return ()) ] -- check that it was processed
      usend rc ()
      -- We may add new field (drive_status)
      False <- expect
      usend rc ()  -- Prepare graph test
      uuid1 <- liftIO $ nextRandom
      usend rc $ HAEvent uuid1 (me, request) [] -- send request
      receiveWait [ matchIf (\u -> u == uuid1) (\_ -> return ()) ] -- check that it was processed
      usend rc ()
      True <- expect
      return ()

testHpiNewWWN :: Transport -> IO ()
testHpiNewWWN = mkHpiTest rules test
  where
    rules self = do
      defineSimple "check-test" $ \() -> do
        rg <- getLocalGraph
        let d = DIIndexInEnclosure 10
        liftProcess $ usend self $ Prelude.null $ (connectedFrom Has d rg :: [StorageDevice])
      defineSimple "disk-failed" $ \d@(DriveRemoved uuid _ _ _) -> do
        liftProcess $ say $ show d
        liftProcess $ usend self (uuid,"message-processed"::String)
    test rc = do
      me <- getSelfNode
      let request = mkResponseHPI "primus.example.com" 10 "loop10" "wwn10"
      uuid <- liftIO $ nextRandom
      usend rc $ HAEvent uuid (me, request) []
      receiveWait [ matchIf (\(u,"message-processed"::String) -> u == uuid) (\_ -> return ()) ]
      usend rc ()
      False <- expect
      return ()

testHpiUpdatedWWN :: Transport -> IO ()
testHpiUpdatedWWN = mkHpiTest rules test
  where
    rules self = do
      defineSimple "check-test" $ \(enc, l) -> do
        let d = DIIndexInEnclosure l
        msd <- lookupStorageDeviceInEnclosure enc d
        forM_ msd $ \sd -> do
          mc <- lookupStorageDeviceReplacement sd
          forM_ mc $ \c -> do
            is <- findStorageDeviceIdentifiers c
            liftProcess $ usend self is
      defineSimple "disk-failed" $ \(DriveRemoved uuid _ enc _) ->
        liftProcess $ usend self (uuid, enc)
    test rc = do
      me   <- getSelfNode
      uuid0 <- liftIO $ nextRandom
      let request0 = mkResponseHPI "primus.example.com" 0 "loop1" "wwn1"
      usend rc $ HAEvent uuid0 (me, request0) []
      let request = mkResponseHPI "primus.example.com" 0 "loop1" "wwn10"
      uuid <- liftIO $ nextRandom
      usend rc $ HAEvent uuid (me, request) []
      enc <- receiveWait [ matchIf (\(u, _) -> u == uuid)
                                   (\(_,enc) -> return enc) ]
      usend rc (enc :: Enclosure, 0::Int)
      is   <- expect
      liftIO $ assertEqual "Indentifiers matches"
                 (Set.fromList [DIIndexInEnclosure 0
                               , DIWWN "wwn10"
                               , DIUUID "loop1"
                               , DISerialNumber "serial"
                               ])
                 (Set.fromList is)

testDMRequest :: Transport -> IO ()
testDMRequest = mkHpiTest rules test
  where
    rules self = do
      defineSimple "prepare" $ \() -> do
        Just sd1 <- lookupStorageDeviceInEnclosure (Enclosure "enclosure1") (DIIndexInEnclosure 1)
        markStorageDeviceRemoved sd1
        liftProcess $ usend self ()
      defineSimple "drive-failed" $ \(DriveFailed uuid _ _ _) ->
        liftProcess $ usend self (uuid, "drive-failed"::String)
      defineSimple "drive-inserted" $ \(DriveInserted uuid _ _) ->
        liftProcess $ usend self (uuid, "drive-inserted"::String)
      defineSimple "drive-removed" $ \(DriveRemoved uuid _ _ _) ->
        liftProcess $ usend self (uuid, "drive-removed"::String)
    test rc = do
        me <- getSelfNode
        let requestA = mkResponseHPI "primus.example.com" 0 "loop1" "wwn1"
        uuidA <- liftIO $ nextRandom
        usend rc $ HAEvent uuidA (me, requestA) []
        let requestB = mkResponseHPI "primus.example.com" 1 "loop2" "wwn2"
        uuidB <- liftIO $ nextRandom
        usend rc $ HAEvent uuidB (me, requestB) []
        --  0  -- active drive
        --  1  -- removed drive
        usend rc ()
        () <- expect
        say "Unused ok for good drive"
        let request0 = dmRequest "unused_ok" "serial1" 0
        uuid0 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid0 (me, request0) []
        "drive-removed" <- await uuid0
        say "Unused ok for removed drive"
        let request1 = dmRequest "unused_ok" "serial1" 1
        uuid1 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid1 (me, request1) []
        "nothing" <- await uuid1
        say "Failed smart for good drive"
        let request2 = dmRequest "failed_smart" "serial1" 0
        uuid2 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid2 (me, request2) []
        "drive-failed" <- await uuid2
        say "Failed smart for removed drive"
        let request3 = dmRequest "failed_smart" "serial1" 1
        uuid3 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid3 (me, request3) []
        "nothing" <- await uuid3
        say "inuse_ok smart for good"
        let request4 = dmRequest "inuse_ok" "serial1" 0
        uuid4 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid4 (me, request4) []
        "nothing" <- await uuid4
        say "inuse_ok smart for bad"
        let request5 = dmRequest "inuse_ok" "serial1" 1
        uuid5 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid5 (me, request5) []
        "drive-inserted" <- await uuid5
        return ()
      where
        await uuid = receiveWait
           [ matchIf (\(u, _) -> u == uuid) (\(_,info) -> return (info::String))
           , matchIf (\u -> u == uuid) (\_ -> return ("nothing"::String))
           ]


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

run :: forall g. g
    -> PhaseM g Int ()
    -> Process (g, [(Buffer, Int)])
run ls = runPhase ls (0 :: Int) emptyFifoBuffer

initialDataAddr :: String -> String -> Int -> CI.InitialData
initialDataAddr host ifaddr n = CI.InitialData {
  CI.id_racks = [
    CI.Rack {
      CI.rack_idx = 1
    , CI.rack_enclosures = [
        CI.Enclosure {
          CI.enc_idx = 1
        , CI.enc_id = "enclosure1"
        , CI.enc_bmc = [CI.BMC host "admin" "admin"]
        , CI.enc_hosts = [
            CI.Host {
              CI.h_fqdn = "primus.example.com"
            , CI.h_memsize = 4096
            , CI.h_cpucount = 8
            , CI.h_interfaces = [
                CI.Interface {
                  CI.if_macAddress = "10-00-00-00-00"
                , CI.if_network = CI.Data
                , CI.if_ipAddrs = [ifaddr]
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
  , CI.m0_pool_width = 16
  , CI.m0_max_rpc_msg_size = 65536
  , CI.m0_uuid = "096051ac-b79b-4045-a70b-1141ca4e4de1"
  , CI.m0_min_rpc_recvq_len = 16
  , CI.m0_lnet_nid = "auto"
  , CI.m0_be_segment_size = 536870912
  , CI.m0_md_redundancy = 2
  , CI.m0_failure_set_gen = CI.Preloaded 0 1 0
  }
, CI.id_m0_servers = [
    CI.M0Host {
      CI.m0h_fqdn = "primus.example.com"
    , CI.m0h_processes = [
        CI.M0Process {
          CI.m0p_endpoint = host ++ "@tcp:12345:41:901"
        , CI.m0p_mem_as = 1
        , CI.m0p_mem_rss = 1
        , CI.m0p_mem_stack = 1
        , CI.m0p_mem_memlock = 1
        , CI.m0p_cores = [1]
        , CI.m0p_services = [
            CI.M0Service {
              CI.m0s_type = CST_MGS
            , CI.m0s_endpoints = [host ++ "@tcp:12345:44:101"]
            , CI.m0s_params = SPConfDBPath "/var/mero/confd"
            }
          , CI.M0Service {
              CI.m0s_type = CST_RMS
            , CI.m0s_endpoints = [host ++ "@tcp:12345:41:301"]
            , CI.m0s_params = SPUnused
            }
          , CI.M0Service {
              CI.m0s_type = CST_MDS
            , CI.m0s_endpoints = [host ++ "@tcp:12345:41:201"]
            , CI.m0s_params = SPUnused
            }
          , CI.M0Service {
              CI.m0s_type = CST_IOS
            , CI.m0s_endpoints = [host ++ "@tcp:12345:41:401"]
            , CI.m0s_params = SPUnused
            }
          ]
        }
    ]
    , CI.m0h_devices = fmap
        (\i -> CI.M0Device ("wwn" ++ show i) 4 64000 ("/dev/loop" ++ show i))
        [(1 :: Int) .. n]
    }
  ]
}



-- | Sample initial data for test purposes
initialData :: CI.InitialData
initialData = initialDataAddr "192.0.2.1" "192.0.2.2" 8
