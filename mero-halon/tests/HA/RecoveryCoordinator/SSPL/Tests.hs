{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
module HA.RecoveryCoordinator.SSPL.Tests
  ( utTests
  ) where

import Control.Distributed.Process.Closure

import qualified Data.Set as Set

import Network.Transport (Transport)
import Network.CEP
import Network.CEP.Testing (runPhase)

import HA.Multimap
import HA.Multimap.Implementation (Multimap, fromList)
import HA.Multimap.Process (startMultimap)
import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Mero
import HA.RecoveryCoordinator.Mero
import HA.RecoveryCoordinator.Events.Drive
import HA.Replicator (RGroup(..))
import HA.Resources
import HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import HA.ResourceGraph hiding (__remoteTable)
import HA.Services.SSPL
import SSPL.Bindings

import Helper.InitialData
import Helper.SSPL
import Helper.RC

import RemoteTables (remoteTable)
import TestRunner
import Data.Binary
import Data.Typeable
import Data.Foldable
import GHC.Generics

import Data.UUID.V4 (nextRandom)
import Data.Text (Text, pack)

import Test.Tasty
import Test.Tasty.HUnit (assertEqual)
import Test.Framework
import Control.Distributed.Process
import Helper.Environment

data GetGraph = GetGraph ProcessId deriving (Eq,Show, Typeable, Generic)

instance Binary GetGraph

mmSDict :: SerializableDict (MetaInfo, Multimap)
mmSDict = SerializableDict

remotable
  [ 'mmSDict ]

myRemoteTable :: RemoteTable
myRemoteTable = HA.RecoveryCoordinator.SSPL.Tests.__remoteTable remoteTable

rGroupTest :: forall g. (Typeable g, RGroup g)
           => Transport -> Proxy g -> (StoreChan -> Process ()) -> IO ()
rGroupTest transport _ p =
  tryRunProcessLocal transport myRemoteTable $ do
    nid <- getSelfNode
    rGroup <- newRGroup $(mkStatic 'mmSDict) "mmtest" 20 1000000 4000000 [nid]
                        (defaultMetaInfo, fromList [])
                >>= unClosure
                >>= (`asTypeOf` return (undefined :: g (MetaInfo, Multimap)))
    (_,mmchan) <- startMultimap rGroup id
    p mmchan

-- List of unit tests
utTests :: (Typeable g, RGroup g) => Transport -> Proxy g -> [TestTree]
utTests transport pg =
   [ testGroup "hpi-requests"
       [ testSuccess "hpi request with existing WWN"
       $ testHpiExistingWWN transport pg
       , testSuccess "hpi request with new resource"
       $ testHpiNewWWN transport pg
       , testSuccess "hpi request with updated WWN"
       $ testHpiUpdatedWWN transport pg
       ]
   , testSuccess "drive-manager-works"
   $ testDMRequest transport pg
   ]

dmRequest :: Text -> Text -> Text -> Int -> Text -> SensorResponseMessageSensor_response_typeDisk_status_drivemanager
dmRequest status reason _serial num path = mkResponseDriveManager "enclosure1" "serial1" (fromIntegral num) status reason path

mkHpiTest ::(Typeable g, RGroup g)
          => (ProcessId -> Definitions LoopState b)
          -> (ProcessId -> Process ())
          -> Transport
          -> Proxy g
          -> IO ()
mkHpiTest mkTestRule test transport pg = rGroupTest transport pg $ \pid -> do
    say "start HPI test"
    self <- getSelfPid
    say "load data"
    ls <- emptyLoopState pid self
    (ls',_)  <- run ls $ do
            mapM_ goRack (CI.id_racks myInitialData)
            filesystem <- initialiseConfInRG
            loadMeroGlobals (CI.id_m0_globals myInitialData)
            loadMeroServers filesystem (CI.id_m0_servers myInitialData)
    let testRule = mkTestRule self
    say "run RC"
    rc <- spawnLocal $ execute ls' $ do
            setLogger $ \l _ -> say (show l)
            _ <- testRule
            _ <- ssplRules
            return ()
    say "start HPI test"
    test rc

testHpiExistingWWN :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
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
      say "prepare"
      usend rc ()  -- Prepare graph test
      let request = mkHpiMessage (pack systemHostname) "enclosure_2" "serial21" 1 "loop21" "wwn21"
      uuid <- liftIO $ nextRandom
      say "send HPI message"
      usend rc $ HAEvent uuid (me, request) [] -- send request
      say "await for reply"
      receiveWait [ matchIf (\u -> u == uuid) (\_ -> return ()) ] -- check that it was processed
      usend rc ()
      -- We may add new field (drive_status)
      say "check that graph did change"
      False <- expect
      usend rc ()  -- Prepare graph test
      uuid1 <- liftIO $ nextRandom
      say "send message again"
      usend rc $ HAEvent uuid1 (me, request) [] -- send request
      receiveWait [ matchIf (\u -> u == uuid1) (\_ -> return ()) ] -- check that it was processed
      usend rc ()
      say "check that graph didn't change"
      True <- expect
      return ()

testHpiNewWWN :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testHpiNewWWN = mkHpiTest rules test
  where
    rules self = do
      defineSimple "check-test" $ \() -> do
        rg <- getLocalGraph
        let d = DIIndexInEnclosure 10
        liftProcess $ usend self $ Prelude.null $ (connectedFrom Has d rg :: [StorageDevice])
    test rc = do
      me <- getSelfNode
      subscribe rc (Proxy :: Proxy (HAEvent (NodeId, SensorResponseMessageSensor_response_typeDisk_status_hpi)))
      let request = mkHpiMessage (pack systemHostname) "enclosure_2" "serial310" 10 "loop10" "wwn10"
      uuid <- liftIO $ nextRandom
      usend rc $ HAEvent uuid (me, request) []
      _ <- expect :: Process (Published (HAEvent (NodeId, SensorResponseMessageSensor_response_typeDisk_status_hpi)))
      usend rc ()
      False <- expect
      return ()

testHpiUpdatedWWN :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testHpiUpdatedWWN = mkHpiTest rules test
  where
    rules self = do
      defineSimple "check-test" $ \(enc, l) -> do
        phaseLog "debug" $ show (enc,l)
        let d = DIIndexInEnclosure l
        msd <- lookupStorageDeviceInEnclosure enc d
        phaseLog "debug" $ show msd
        forM_ msd $ \sd -> do
          mc <- lookupStorageDeviceReplacement sd
          forM_ mc $ \c -> do
            is <- findStorageDeviceIdentifiers c
            liftProcess $ usend self is
      defineSimple "disk-failed" $ \(DriveRemoved uuid _ enc _ _) ->
        liftProcess $ usend self (uuid, enc)
    test rc = do
      me   <- getSelfNode
      uuid0 <- liftIO $ nextRandom
      subscribe rc (Proxy :: Proxy (HAEvent (NodeId, SensorResponseMessageSensor_response_typeDisk_status_hpi)))
      let request0 = mkHpiMessage (pack systemHostname) "enclosure_2" "serial21" 1 "loop1" "wwn1"
      usend rc $ HAEvent uuid0 (me, request0) []
      let request = mkHpiMessage (pack systemHostname) "enclosure_2" "serial31" 1 "loop1" "wwn10"
      uuid <- liftIO $ nextRandom
      usend rc $ HAEvent uuid (me, request) []
      _ <- expect :: Process (Published (HAEvent (NodeId, SensorResponseMessageSensor_response_typeDisk_status_hpi)))
      _ <- expect :: Process (Published (HAEvent (NodeId, SensorResponseMessageSensor_response_typeDisk_status_hpi)))
      usend rc (Enclosure "enclosure_2", 1::Int)
      is   <- expect
      liftIO $ assertEqual "Indentifiers matches"
                 (Set.fromList [DIIndexInEnclosure 1
                               , DIWWN "wwn10"
                               , DISerialNumber "serial31"
                               ])
                 (Set.fromList is)

testDMRequest :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testDMRequest = mkHpiTest rules test
  where
    rules self = do
      defineSimple "prepare" $ \() -> do
        Just sd1 <- lookupStorageDeviceInEnclosure (Enclosure "enclosure1") (DIIndexInEnclosure 1)
        markStorageDeviceRemoved sd1
        liftProcess $ usend self ()
      defineSimple "drive-failed" $ \(DriveFailed uuid _ _ _) ->
        liftProcess $ usend self (uuid, "drive-failed"::String)
      defineSimple "drive-ok" $ \(DriveOK uuid _ _ _) ->
        liftProcess $ usend self (uuid, "drive-ok"::String)
      defineSimple "drive-transient" $ \(DriveTransient uuid _ _ _) ->
        liftProcess $ usend self (uuid, "drive-transient"::String)
    test rc = do
        me <- getSelfNode
        let requestA = mkHpiMessage "primus.example.com" "enclosure1" "serial1" 0 "loop1" "wwn1"
        uuidA <- liftIO $ nextRandom
        usend rc $ HAEvent uuidA (me, requestA) []
        let requestB = mkHpiMessage "primus.example.com" "enclosure1" "serial2" 1 "loop2" "wwn2"
        uuidB <- liftIO $ nextRandom
        usend rc $ HAEvent uuidB (me, requestB) []
        --  0  -- active drive
        --  1  -- removed drive
        usend rc ()
        () <- expect
        say "Unused ok for good drive"
        let request0 = dmRequest "EMPTY" "None" "serial1" 0 "path"
        uuid0 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid0 (me, request0) []
        "drive-transient" <- await uuid0
        say "Unused ok for removed drive"
        let request1 = dmRequest "EMPTY" "None" "serial1" 1 "path"
        uuid1 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid1 (me, request1) []
        "nothing" <- await uuid1
        say "Failed smart for good drive"
        let request2 = dmRequest "FAILED" "SMART" "serial1" 0 "path"
        uuid2 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid2 (me, request2) []
        "drive-failed" <- await uuid2
        say "Failed smart for removed drive"
        let request3 = dmRequest "FAILED" "SMART" "serial1" 1 "path"
        uuid3 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid3 (me, request3) []
        "nothing" <- await uuid3
        say "OK_None smart for good"
        let request4 = dmRequest "OK" "None" "serial1" 0 "path"
        uuid4 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid4 (me, request4) []
        await uuid4 >>= liftIO . assertEqual "OK_None smart for good" "drive-ok"
        say "OK_None smart for bad"
        let request5 = dmRequest "OK" "None" "serial1" 1 "path"
        uuid5 <- liftIO $ nextRandom
        usend rc $ HAEvent uuid5 (me, request5) []
        await uuid5 >>= liftIO . assertEqual "OK_None smart for bad" "nothing"
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

-- | Sample initial data for test purposes
myInitialData :: CI.InitialData
myInitialData = initialData systemHostname testListenName 1 12 defaultGlobals
