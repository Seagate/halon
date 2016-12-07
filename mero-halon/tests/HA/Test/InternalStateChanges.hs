{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Exercise the internal state change mechanism
module HA.Test.InternalStateChanges (mkTests) where

import           Control.Distributed.Process hiding (bracket)
import           Control.Exception as E
import           Control.Lens
import           Data.Binary (Binary)
import           Data.Maybe (listToMaybe, mapMaybe)
import           Data.Typeable
import           Data.Vinyl
import           GHC.Generics (Generic)
import qualified HA.Castor.Story.Tests as H
import           HA.RecoveryCoordinator.Helpers
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Mero.Notifications
import           HA.RecoveryCoordinator.Mero.State
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import           HA.RecoveryCoordinator.RC.Actions.Dispatch
import           HA.Replicator hiding (getState)
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
import           TestRunner (ta_rc)

mkTests :: (Typeable g, RGroup g) => Proxy g -> IO (Transport -> [TestTree])
mkTests pg = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (e::AMQPException) -> return $ \_->
      [testSuccess ("InternalStateChange tests disabled (can't connect to rabbitMQ): "++show e)  $ return ()]
    Right x -> do
      closeConnection x
      return $ \t ->
        [ testSuccess "stateCascade" $
           stateCascade t pg
        ,testSuccess "failureVector" $
           failvecCascade t pg
        ]

-- | Used to fire internal test rules
newtype RuleHook = RuleHook ProcessId
  deriving (Generic, Typeable, Binary)

-- | Test that internal object change message is properly sent out
-- throughout RC for a cascaded event.
--
-- Relies on @processCascadeRule@. Set a process to Online and make
-- sure a notification goes out for both the process and services
-- belonging to that process.
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
stateCascade t pg = H.run t pg [rule] (\ta _ recv _ -> test' (ta_rc ta) recv)
  where
    test' :: ProcessId -> ReceivePort NotificationMessage -> Process ()
    test' rc recv = do
      self <- getSelfPid
      _ <- usend rc $ RuleHook self
      _ <- H.spawnNotificationAcker recv
      expect >>= \case
        Left e -> fail e
        Right True -> return ()
        Right False -> fail "Process/service in unexpected state."

    rule :: Definitions RC ()
    rule = define "stateCascadeTest" $ do
      init_rule <- phaseHandle "init_rule"
      notified <- phaseHandle "notified"
      timed_out <- phaseHandle "timed_out"
      dispatch <- mkDispatcher
      notifier <- mkNotifierSimple dispatch

      setPhase init_rule $ \(RuleHook pid) -> do
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
            srvs = G.connectedTo p M0.IsParentOf rg :: [M0.Service]
        liftProcess $ usend pid p


        let notifySet = stateSet p Tr.processStarting
                      : map (`stateSet` Tr.processCascadeService M0.PSStarting) srvs

        modify Local $ rlens fldPid . rfield .~ Just pid
        modify Local $ rlens fldProcess . rfield .~ Just p

        setExpectedNotifications notifySet
        applyStateChanges [stateSet p Tr.processStarting]

        waitFor notifier
        onTimeout 10 timed_out
        onSuccess notified
        continue dispatch

      directly notified $ do
        phaseLog "info" $ "All notified"
        Just pid <- getField . rget fldPid <$> get Local
        Just p <- getField . rget fldProcess <$> get Local
        rg <- getLocalGraph
        let pstate = getState p rg == M0.PSStarting
            sstate = all (== M0.SSStarting)
              [ getState s rg | (s :: M0.Service) <- G.connectedTo p M0.IsParentOf rg ]

        liftProcess $ usend pid (Right (pstate && sstate) :: Either String Bool)

      directly timed_out $ do
        Just pid <- getField . rget fldPid <$> get Local
        liftProcess . usend pid $ (Left "Notification timed out" :: Either String Bool)

      start init_rule args
      where
        fldPid = Proxy :: Proxy '("caller", Maybe ProcessId)
        fldProcess = Proxy :: Proxy '("proc", Maybe M0.Process)

        args = fldNotifications =: []
           <+> fldPid           =: Nothing
           <+> fldDispatch      =: Dispatch [] (error "stateCascade.rule dispatcher") Nothing
           <+> fldProcess       =: Nothing

failvecCascade :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
failvecCascade t pg = H.run t pg [rule] (\ta _ recv _ -> test' (ta_rc ta) recv)
  where
    test' :: ProcessId -> ReceivePort NotificationMessage -> Process ()
    test' rc recv = do
      self <- getSelfPid
      usend rc $ RuleHook self
      (d0:d1:_disks) <- expect :: Process [M0.Disk]
      Set _ <- H.nextNotificationFor (M0.fid d0) recv
      mfailvec <- expect :: Process (Maybe [Note])
      sayTest $ "Notifications: " ++ show mfailvec
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
      dispatch <- mkDispatcher
      notifier <- mkNotifierSimple dispatch

      setPhase init_rule $ \(RuleHook pid) -> do
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

        modify Local $ rlens fldPid . rfield .~ Just pid

        setExpectedNotifications failure_set
        applyStateChanges failure_set

        waitFor notifier
        onTimeout 15 timed_out
        onSuccess notified
        continue dispatch

      directly notified $ do
        phaseLog "info" $ "All notified"
        Just pid <- getField . rget fldPid <$> get Local

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
          [] -> liftProcess $ usend pid (Nothing :: Maybe NVec)
          (mv:_) -> do
            phaseLog "mvs" $ show mvs
            liftProcess . usend pid $ Just mv

      directly timed_out $ do
        Just pid <- getField . rget fldPid <$> get Local
        liftProcess $ usend pid (Nothing :: Maybe NVec)

      start init_rule args
      where
        fldPid = Proxy :: Proxy '("caller", Maybe ProcessId)

        args = fldNotifications =: []
           <+> fldPid           =: Nothing
           <+> fldDispatch      =: Dispatch [] (error "failvecCascade.rule dispatcher") Nothing
