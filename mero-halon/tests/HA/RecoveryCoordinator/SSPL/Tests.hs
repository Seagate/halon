{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}
-- |
-- Module    : HA.RecoveryCoordinator.SSPL.Tests
-- Copyright : (C) 2016-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- SSPL-related unit tests
module HA.RecoveryCoordinator.SSPL.Tests
  ( utTests
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Monad (unless)
import           Data.Binary
import           Data.Bool (bool)
import qualified Data.ByteString.Lazy.Char8 as B8
import           Data.List (intercalate)
import           Data.Text (Text, pack)
import           Data.Typeable
import           Data.UUID.V4 (nextRandom)
import           GHC.Generics
import qualified HA.Aeson as A
import           HA.EventQueue.Types
import           HA.Multimap
import           HA.Multimap.Implementation (Multimap, fromList)
import           HA.Multimap.Process (startMultimap)
import           HA.RecoveryCoordinator.Actions.Mero
import           HA.RecoveryCoordinator.Castor.Drive.Events
import           HA.RecoveryCoordinator.Castor.Rules (goSite)
import qualified HA.RecoveryCoordinator.Hardware.StorageDevice.Actions as StorageDevice
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero
import           HA.Replicator (RGroup(..))
import qualified HA.ResourceGraph as G
import           HA.Resources.Castor
import qualified HA.Resources.Castor.Initial as CI
import           HA.Services.SSPL.LL.CEP (ssplRules)
import           HA.Services.SSPL.LL.Resources (SsplLlFromSvc(..))
import           Helper.InitialData
import           Helper.RC
import           Helper.SSPL
import           Network.BSD (getHostName)
import           Network.CEP
import           Network.CEP.Testing (runPhase)
import           Network.Transport (Transport)
import           RemoteTables (remoteTable)
import           SSPL.Bindings
import           Test.Framework
import           Test.Tasty.HUnit (assertBool)
import           TestRunner

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
   [ mkHpiTests transport pg
   , testSuccess "drive-manager-works"
   $ testDMRequest transport pg
   ]

dmRequest :: Text -> Text -> Text -> Int -> Text -> SensorResponseMessageSensor_response_typeDisk_status_drivemanager
dmRequest status reason serial num path = mkResponseDriveManager "enclosure_15" serial (fromIntegral num) status reason path

mkHpiTest :: (Typeable g, RGroup g)
          => (ProcessId -> Definitions RC b)
          -> (ProcessId -> Process ())
          -> Transport
          -> Proxy g
          -> IO ()
mkHpiTest mkTestRule test transport pg = rGroupTest transport pg $ \pid -> do
    sayTest "start HPI test"
    self <- getSelfPid
    sayTest "load data"
    ls <- emptyLoopState pid self
    iData@CI.InitialData{..} <- liftIO defaultInitialData
    sayTest $ show iData
    (ls',_)  <- run ls $ do
            mapM_ goSite id_sites
            initialiseConfInRG
            loadMeroGlobals id_m0_globals
            loadMeroServers id_m0_servers
            loadMeroPools id_pools >>= loadMeroProfiles id_profiles
    let testRule = mkTestRule self
    sayTest "run RC"
    rc <- spawnLocal $ execute ls' $ do
            setLogger $ \l _ -> sayTest (B8.unpack $ A.encode l)
            _ <- testRule
            _ <- ssplRules
            return ()
    sayTest "start HPI test"
    test rc

-- | Information about HPI related test.
data HpiTestInfo = HTI
       { hpiWasInstalled :: Bool -- ^ If drive was installed before test
       , hpiWasPowered   :: Bool -- ^ If drive was powered before test
       , hpiIsNew        :: Bool -- ^ If new drive was inserted
       , hpiIsInstalled  :: Bool -- ^ If drive inserted or removed
       , hpiIsPowered    :: Bool -- ^ If drive is powered now
       , hpiUserCallback :: UUID -> Process ()
       }

-- | ruleMonitorStatusHpi-extracted DiskHpi message
type HpiRuleMsg = (UUID, NodeId, SensorResponseMessageSensor_response_typeDisk_status_hpi)

type DriveManagerRuleMsg = (UUID, NodeId, SensorResponseMessageSensor_response_typeDisk_status_drivemanager)

hpiTests :: [HpiTestInfo]
hpiTests =
  --     installed  powered new    powered installed
  -- nothing changed
  [ HTI   a         b       False  a       b         $ \_uuid -> no_other_events
  | (a,b) <- (,) <$> [True, False] <*> [True, False]] ++
  -- power changed
  [ HTI   True      a       False  True    (not a)   $ \_uuid -> do
     receiveWait $ oneMatch $ matchIf (\(Published (DrivePowerChange _ _ _ _ x) _) -> x == not a)
                                      (const $ return ())
     no_other_events
  | a <- [True, False]] ++
  -- Remove drive
  [ HTI   True      a       False  False   b         $ \_uuid -> do
     receiveWait $ oneMatch  $ matchIf (\(Published (DriveRemoved _ _ _ _ (Just x)) _) -> x == b)
                                       (const $ return ())
     no_other_events
  | (a,b) <- (,) <$> [True, False] <*> [True, False]] ++
  -- Insert drive
  [ HTI   False     a       False  True    b         $ \_uuid -> do
     receiveWait $ oneMatch $ matchIf (\(Published (DriveInserted _ _ _ _ (Just x)) _) -> x == b)
                                      (const $ return ())
     no_other_events
  | (a,b) <- (,) <$> [True, False] <*> [True, False]] ++
  -- New drive not inserted
  [ HTI   False     a       True   False   b         $ \_uuid -> no_other_events
  | (a,b) <- (,) <$> [True, False] <*> [True, False]] ++
  [ HTI   False     a       True   True    b         $ \_uuid -> do
     receiveWait $ oneMatch $ match $ \(_ :: Published DriveInserted) -> return ()
     no_other_events
  | (a,b) <- (,) <$> [True, False] <*> [True, False]] ++
  [ HTI   True      a        True  True    b         $ \_uuid -> do
     -- Require slot info on the old drive
     receiveWait [match (\(_ :: Published DriveRemoved) -> return ())]
     receiveWait [match (\(_ :: Published DriveInserted) -> return ())]
     no_other_events
  | (a,b) <- (,) <$> [True, False] <*> [True, False]]
  where
  isDiskHpi :: Published HpiRuleMsg -> Bool
  isDiskHpi _ = True

  no_other_events = receiveWait
    [ matchIf isDiskHpi (\_ -> return ())
    , match $ \(_ :: Published DrivePowerChange) -> error "drive power change emitted"
    , match $ \(_ :: Published DriveInserted) -> error "drive inserted emitted"
    , match $ \(_ :: Published DriveRemoved) -> error "drive removed emitted"
    ]
  oneMatch m = m:
    [ matchIf isDiskHpi (\_ -> error "no interesting event")
    , match $ \(_ :: Published DrivePowerChange) -> error "drive power change emitted"
    , match $ \(_ :: Published DriveInserted) -> error "drive inserted emitted"
    , match $ \(_ :: Published DriveRemoved) -> error "drive removed emitted"
    ]

mkHpiTests :: (Typeable g, RGroup g) => Transport -> Proxy g -> TestTree
mkHpiTests tr p = testGroup "HPI"
    $ map (\info -> testSuccess (mkTestName info) $ genericHpiTest info tr p) hpiTests
  where
    mkTestName :: HpiTestInfo -> String
    mkTestName HTI{..} =
      intercalate ";" [bool "was_removed" "was_installed" hpiWasInstalled
                      ,bool "was_poweredoff" "was_poweredon" hpiWasPowered
                      ,bool "same" "new" hpiIsNew
                      ,bool "removed" "installed" hpiIsInstalled
                      ,bool "poweredoff" "poweredon" hpiIsPowered
                      ]

data GiveMeEnclosureName = GiveMeEnclosureName deriving (Typeable, Generic)

instance Binary GiveMeEnclosureName

genericHpiTest :: (Typeable g, RGroup g) => HpiTestInfo -> Transport -> Proxy g -> IO ()
genericHpiTest HTI{..} = mkHpiTest rules test
  where
    rules _self = do
      define "init-drive" $ do
        ph0 <- phaseHandle "init"
        ph1 <- phaseHandle "finish"
        directly ph0 $ do
           [e] <- take 1 . G.getResourcesOfType <$> getGraph
           let Enclosure ('e':'n':'c':'l':'o':'s':'u':'r':'e':'_':ide) = e
           let serial = "serial" ++ ide ++ "_1"
           let sdev = StorageDevice serial
           unless hpiWasInstalled $ do
             loc <- StorageDevice.mkLocation e 1
             _   <- StorageDevice.insertTo sdev loc
             _   <- StorageDevice.ejectFrom sdev loc
             return ()
           unless hpiWasPowered $ do
             StorageDevice.poweroff sdev
           continue ph1
        directly ph1 $ stop
        start ph0 ()
      defineSimple "enclosure" $ \(GiveMeEnclosureName, pid) -> do
        [e] <- take 1 . G.getResourcesOfType <$> getGraph
        liftProcess $ usend pid (e::Enclosure)
    test rc = do
      self <- getSelfPid
      usend rc (GiveMeEnclosureName, self)
      Enclosure e@('e':'n':'c':'l':'o':'s':'u':'r':'e':'_':ide) <- expect
      let serial = "serial" ++ ide ++ "_1"
      let (enc, serial', idx, devid, wwn, _sdev) =
            if hpiIsNew
            then (pack e, serial++"new", 1, pack $ "/dev/loop" ++ ide ++"_new", pack $ "wwn" ++ ide ++"_1new", StorageDevice $ serial++"new")
            else (pack e, serial, 1, pack $ "/dev/loop" ++ ide ++ "_1", pack $ "wwn" ++ ide ++ "_1", StorageDevice serial)

      subscribe rc (Proxy :: Proxy HpiRuleMsg)
      subscribe rc (Proxy :: Proxy DrivePowerChange)
      subscribe rc (Proxy :: Proxy DriveInserted)
      subscribe rc (Proxy :: Proxy DriveRemoved)

      -- Send HPI message:
      me   <- getSelfNode
      uuid <- liftIO nextRandom
      hostname <- liftIO getHostName
      let request = mkHpiMessage (pack hostname) enc (pack serial') idx devid wwn hpiIsInstalled hpiIsPowered
      usend rc . HAEvent uuid $ DiskHpi me request
      hpiUserCallback uuid

testDMRequest :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
testDMRequest = mkHpiTest rules test
  where
    rules self = do
      defineSimple "prepare" $ \() -> do
        -- Just sd1 <- lookupStorageDeviceInEnclosure (Enclosure "enclosure1") (DIIndexInEnclosure 1)
        -- markStorageDeviceRemoved sd1
        liftProcess $ usend self ()
    test rc = do
        subscribe rc (Proxy :: Proxy HpiRuleMsg)
        subscribe rc (Proxy :: Proxy DriveManagerRuleMsg)
        subscribe rc (Proxy :: Proxy DriveFailed)
        subscribe rc (Proxy :: Proxy DriveOK)
        subscribe rc (Proxy :: Proxy DriveTransient)
        me <- getSelfNode
        let requestA = mkHpiMessage "devvm.seagate.com" "enclosure_15" "serial15_1" 1 "/dev/loop15_1" "wwn15_1" True True
        uuidA <- liftIO $ nextRandom
        usend rc . HAEvent uuidA $ DiskHpi me requestA
        _ :: HpiRuleMsg <- expectPublished
        let requestB = mkHpiMessage "primus.example.com" "enclosure_15" "serial15_2" 2 "/dev/loop15_2" "wwn15_2" True True
        uuidB <- liftIO $ nextRandom
        usend rc . HAEvent uuidB $ DiskHpi me requestB
        _ :: HpiRuleMsg <- expectPublished
        --  0  -- active drive
        --  1  -- removed drive
        usend rc ()
        () <- expect
        sayTest "Unused ok for good drive"
        let request0 = dmRequest "EMPTY" "None" "serial15_1" 1 "path"
        uuid0 <- liftIO $ nextRandom
        usend rc . HAEvent uuid0 $ DiskStatusDm me request0
        liftIO . assertBool "drive become transient" =<< await uuid0
          (match (\(_ :: Published DriveTransient) -> return True))
        clean

        sayTest "Unused ok for removed drive"
        let request1 = dmRequest "EMPTY" "None" "serial15_1" 1 "path"
        uuid1 <- liftIO $ nextRandom
        usend rc . HAEvent uuid1 $ DiskStatusDm me request1
        liftIO . assertBool "drive become transient" =<< await uuid1
          (match (\(_ :: Published DriveManagerRuleMsg) -> return True))

        sayTest "Failed smart"
        let request2 = dmRequest "FAILED" "SMART" "serial15_1" 1 "path"
        uuid2 <- liftIO $ nextRandom
        usend rc . HAEvent uuid2 $ DiskStatusDm me request2
        liftIO . assertBool "drive is failed now" =<< await uuid2
          (match (\(_ :: Published DriveFailed) -> return True))
        clean

        sayTest "Failed smart for failed drive"
        let request3 = dmRequest "FAILED" "SMART" "serial15_1" 1 "path"
        uuid3 <- liftIO $ nextRandom
        usend rc . HAEvent uuid3 $ DiskStatusDm me request3
        liftIO . assertBool "drive become transient" =<< await uuid3
          (match (\(_ :: Published DriveManagerRuleMsg) -> return True))

        sayTest "OK_None smart for failed"
        let request4 = dmRequest "OK" "None" "serial1" 0 "path"
        uuid4 <- liftIO $ nextRandom
        usend rc . HAEvent uuid4 $ DiskStatusDm me request4
        liftIO . assertBool "drive is good now" =<< await uuid4
          (match (\(_ :: Published DriveOK) -> return True))
        clean

        sayTest "OK_None smart for ok"
        let request5 = dmRequest "OK" "None" "serial1" 0 "path"
        uuid5 <- liftIO $ nextRandom
        usend rc . HAEvent uuid4 $ DiskStatusDm me request5
        liftIO . assertBool "drive still ok" =<< await uuid5
          (match (\(_ :: Published DriveManagerRuleMsg) -> return True))
        _ <- receiveTimeout 2000000 [] -- HALON-590
        return ()
      where
        await _uuid m = receiveWait
           [ m
           , match $ \(_ :: Published DriveManagerRuleMsg)
               -> return False
           ]
        clean = receiveWait
           [ match $ \(_ :: Published DriveManagerRuleMsg)
               -> return ()
           ]

run :: forall app g. (Application app, g ~ GlobalState app)
    => g
    -> PhaseM app Int ()
    -> Process (g, [(Buffer, Int)])
run ls = runPhase ls (0 :: Int) emptyFifoBuffer
