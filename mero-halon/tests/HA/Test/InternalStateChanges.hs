{-# LANGUAGE OverloadedStrings #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Exercise the internal state change mechanism
module HA.Test.InternalStateChanges (mkTests) where

import           Control.Distributed.Process hiding (bracket)
import           Control.Lens
import           Control.Exception as E
import           Data.Binary (Binary)
import           Data.List (sort)
import           Data.Maybe (listToMaybe, fromMaybe, mapMaybe)
import           Data.Typeable
import           GHC.Generics (Generic)
import qualified HA.Castor.Story.Tests as H
import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Mero.State
import           HA.Replicator
import qualified HA.ResourceGraph as G
import           HA.Resources
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.Services.Mero
import           Mero.Notification
import           Mero.Notification.HAState
import           Network.AMQP
import           Network.CEP
import           Network.Transport
import           Test.Framework
import           Test.Tasty.HUnit (assertEqual, assertBool, assertFailure)
import           TestRunner

mkTests :: (Typeable g, RGroup g) => Proxy g -> IO (Transport -> [TestTree])
mkTests pg = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (e::AMQPException) -> return $ \_->
      [testSuccess ("InternalStateChange tests disabled (can't connect to rabbitMQ): "++show e)  $ return ()]
    Right x -> do
      closeConnection x
      return $ \t ->
        [testSuccess "stateCascade" $
           stateCascade t pg
        ,testSuccess "failureVector" $
           failvecCascade t pg
        ]

-- | Used to fire internal test rules
newtype RuleHook = RuleHook ProcessId
  deriving (Generic, Typeable)
instance Binary RuleHook

doTest :: (Typeable g, RGroup g)
     => Transport
     -> Proxy g
     -> [Definitions RC ()]
     -> (ReceivePort NotificationMessage -> Process ())
     -> IO ()
doTest t pg rules test' = H.run t pg interceptor rules test where
  interceptor _ _ = return ()
  test (TestArgs _ _ rc) rmq recv _ = do
    H.prepareSubscriptions rc rmq
    test' recv

-- | Test that internal object change message is properly sent out
-- throughout RC for a cascaded event.
--
-- Relies on @processCascadeRule@. Set a process to Online and make
-- sure a notification goes out for both the process and services
-- belonging to that process.
--
-- * Load initial data
--
-- * Mark process as online
--
-- * Wait until internal notification for process and services
-- happens: this tests HALON-269 fix and without it times out
--
-- As bonus steps:
--
-- * Send the expected mero messages to the test runner
--
-- * Compare the messages we're expecting with the messages actually sent out
stateCascade :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
stateCascade t pg = doTest t pg [rule] test'
  where
    test' :: ReceivePort NotificationMessage -> Process ()
    test' recv = do
      nid <- getSelfNode
      self <- getSelfPid
      _ <- promulgateEQ [nid] $ RuleHook self
      ps <- expect :: Process M0.Process
      Set ns' <- H.nextNotificationFor (M0.fid ps) recv
      H.debug $ "Received: " ++ show ns'
      Set ns <- expect
      H.debug $ "Expected: " ++ show ns
      liftIO $ assertEqual "Mero gets the expected note set" (sort ns) (sort ns')

    rule :: Definitions RC ()
    rule = define "stateCascadeTest" $ do
      init_rule <- phaseHandle "init_rule"
      notified <- phaseHandle "notified"
      timed_out <- phaseHandle "timed_out"

      let viewNotifySet :: Lens' (Maybe (UUID,ProcessId,[AnyStateSet],NVec)) (Maybe [AnyStateSet])
          viewNotifySet = lens lget lset where
            lset Nothing _ = Nothing
            lset (Just (a,b,_,d)) x = Just (a,b,fromMaybe [] x,d)
            lget = fmap (\(_,_,x,_) -> x)

      setPhase init_rule $ \(HAEvent eid (RuleHook pid)) -> do
        rg <- getLocalGraph
        let Just p = listToMaybe $
                [ proc | Just (prof :: M0.Profile) <- [G.connectedTo Cluster Has rg]
                , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
                , (rack :: M0.Rack) <- G.connectedTo fs M0.IsParentOf rg
                , (encl :: M0.Enclosure) <- G.connectedTo rack M0.IsParentOf rg
                , (ctrl :: M0.Controller) <- G.connectedTo encl M0.IsParentOf rg
                , Just (node :: M0.Node) <- [G.connectedFrom M0.IsOnHardware ctrl rg]
                , (proc :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
                ]
            -- Just encl = listToMaybe
            --           $ (G.connectedTo p M0.IsParentOf rg :: [M0.Enclosure])
            -- Just ctrl = listToMaybe
            --           $ (G.connectedTo encl M0.IsParentOf rg :: [M0.Controller])
            -- Just node = listToMaybe
            --           $ (G.connectedFrom M0.IsOnHardware ctrl rg :: [M0.Node])
            -- procs = G.connectedTo node M0.IsParentOf rg :: [M0.Process]
            srvs = G.connectedTo p M0.IsParentOf rg :: [M0.Service]
        liftProcess . usend pid $ p
        applyStateChanges [stateSet p Tr.processOnline]
        let notifySet = stateSet p Tr.processOnline
                      : (flip stateSet Tr.serviceOnline <$> srvs)
            meroSet = Note (M0.fid p) M0_NC_ONLINE
                    : (flip Note M0_NC_ONLINE . M0.fid <$> srvs)
        put Local $ Just (eid, pid, notifySet, meroSet)
        switch [notified, timeout 15 timed_out]

      setPhaseAllNotified notified viewNotifySet $ do
        Just (eid, pid, _, meroSet) <- get Local
        phaseLog "info" $ "All notified"
        liftProcess . usend pid $ Set meroSet
        messageProcessed eid

      directly timed_out $ do
        Just (eid, _, notifySet, _) <- get Local
        phaseLog "warn" $ "Notify timed out"
        phaseLog "info" $ "Expecting " ++ (show $ length notifySet) ++ " notes."
        messageProcessed eid

      start init_rule Nothing

failvecCascade :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
failvecCascade t pg = doTest t pg [rule] test'
  where
    test' :: ReceivePort NotificationMessage -> Process ()
    test' recv = do
      nid <- getSelfNode
      self <- getSelfPid
      _ <- promulgateEQ [nid] $ RuleHook self
      (d0:d1:_disks) <- expect :: Process [M0.Disk]
      Set _ <- H.nextNotificationFor (M0.fid d0) recv
      mfailvec <- expect :: Process (Maybe [Note])
      H.debug $ "Notifications: " ++ show mfailvec
      case mfailvec of
        Just failvec -> do
          liftIO $ assertEqual "Mero sends both devices" 2 (length failvec)
          liftIO $ assertEqual "Mero sends devices in right order"
                   [M0.fid d0, M0.fid d1]
                   (map (\(Note f _) -> f) failvec)
          liftIO $ assertBool "All devices are failed" $
                   all (\(Note _ s) -> s == M0_NC_FAILED) failvec
        Nothing -> liftIO $ assertFailure "no failvector received"

    rule :: Definitions RC ()
    rule = define "stateCascadeTest" $ do
      init_rule <- phaseHandle "init_rule"
      notified <- phaseHandle "notified"
      timed_out <- phaseHandle "timed_out"

      let viewNotifySet :: Lens' (Maybe (UUID,ProcessId,[AnyStateSet],NVec)) (Maybe [AnyStateSet])
          viewNotifySet = lens lget lset where
            lset Nothing _ = Nothing
            lset (Just (a,b,_,d)) x = Just (a,b,fromMaybe [] x,d)
            lget = fmap (\(_,_,x,_) -> x)

      setPhase init_rule $ \(HAEvent eid (RuleHook pid)) -> do
        phaseLog "info" "Set hooks"
        rg <- getLocalGraph
        let disks@(d0:d1:_) =
                [ disk | Just (prof :: M0.Profile) <- [G.connectedTo Cluster Has rg]
                , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
                , (rack :: M0.Rack) <- G.connectedTo fs M0.IsParentOf rg
                , (enclosure :: M0.Enclosure) <- G.connectedTo rack M0.IsParentOf rg
                , (controller :: M0.Controller) <- G.connectedTo enclosure M0.IsParentOf rg
                , (disk :: M0.Disk) <- G.connectedTo controller M0.IsParentOf rg
                ]
        liftProcess . usend pid $ disks
        let failure_set = [stateSet d0 Tr.diskFailed, stateSet d1 Tr.diskFailed]
        applyStateChanges failure_set
        let meroSet = [ Note (M0.fid d0) M0_NC_FAILED
                      , Note (M0.fid d1) M0_NC_TRANSIENT
                      ]
        put Local $ Just (eid, pid, failure_set, meroSet)
        switch [notified, timeout 15 timed_out]

      setPhaseAllNotified notified viewNotifySet $ do
        Just (eid, pid, _, _) <- get Local
        phaseLog "info" $ "All notified"
        rg <- getLocalGraph
        let pools =
                [ pool | Just (prof :: M0.Profile) <- [G.connectedTo Cluster Has rg]
                , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
                , (pool :: M0.Pool) <- G.connectedTo fs M0.IsParentOf rg
                ]
        let mvs = mapMaybe (\pl -> (\(M0.DiskFailureVector v) -> (\w -> Note (M0.fid w)
                 (toConfObjState w (HA.Resources.Mero.Note.getState w rg))) <$> v)
              <$> (G.connectedTo pl Has rg)) pools
        case mvs of
          [] -> liftProcess . usend pid $ (Nothing :: Maybe [Note])
          (mv:_) -> do
            phaseLog "mvs" $ show mvs
            liftProcess . usend pid $ Just mv
        messageProcessed eid

      directly timed_out $ do
        Just (eid, _, _, _) <- get Local
        phaseLog "warn" $ "Notify timed out"
        messageProcessed eid

      start init_rule Nothing
