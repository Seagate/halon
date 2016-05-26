-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Exercise the internal state change mechanism
module HA.Test.InternalStateChanges (tests) where

import           Control.Distributed.Process hiding (bracket)
import           Data.Binary (Binary)
import           Data.List (sort)
import           Data.Maybe (listToMaybe)
import           Data.Typeable
import           GHC.Generics (Generic)
import qualified HA.Castor.Story.Tests as H
import           HA.EventQueue.Producer
import           HA.EventQueue.Types
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Rules.Mero.Conf
import           HA.Replicator
import qualified HA.ResourceGraph as G
import           HA.Resources
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import           HA.Services.Mero
import           Mero.Notification
import           Mero.Notification.HAState
import           Network.CEP
import           Network.Transport
import           Test.Framework
import           Test.Tasty.HUnit (assertEqual)
import           TestRunner

tests :: (Typeable g, RGroup g) => Transport -> Proxy g -> [TestTree]
tests t pg = [testSuccess "processOfflinesServices" $
                processOfflinesServices t pg
             ]

-- | Used to fire internal test rules
newtype RuleHook = RuleHook ProcessId
  deriving (Generic, Typeable)
instance Binary RuleHook

doTest :: (Typeable g, RGroup g)
     => Transport
     -> Proxy g
     -> [Definitions LoopState ()]
     -> (ReceivePort NotificationMessage -> Process ())
     -> IO ()
doTest t pg rules test' = H.run t pg interceptor rules test where
  interceptor _ _ = return ()
  test (TestArgs _ _ rc) rmq recv = do
    H.prepareSubscriptions rc rmq
    H.loadInitialData
    test' recv

-- | Test that internal object change message is properly sent out
-- throughout RC for a cascaded event.
--
-- Relies on @processCascadeRule@. Set a process to Offline and make
-- sure a notification goes out for both the process and services
-- belonging to that process.
--
-- * Load initial data
--
-- * Mark process as offline
--
-- * Wait until internal notification for process and services
-- happens: this tests HALON-269 fix and without it times out
--
-- As bonus steps:
--
-- * Send the expected mero messages to the test runner
--
-- * Compare the messages we're expecting with the messages actually sent out
processOfflinesServices :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
processOfflinesServices t pg = doTest t pg [rule] test'
  where
    test' :: ReceivePort NotificationMessage -> Process ()
    test' recv = do
      nid <- getSelfNode
      self <- getSelfPid
      _ <- promulgateEQ [nid] $ RuleHook self
      Just (Set ns) <- expectTimeout 20000000
      Just (Set ns') <- fmap notificationMessage <$> receiveChanTimeout 2000000 recv
      liftIO $ assertEqual "Mero gets the expected note set" (sort ns) (sort ns')

    rule :: Definitions LoopState ()
    rule = define "processOfflinesServicesTest" $ do
      init_rule <- phaseHandle "init_rule"
      notified <- phaseHandle "notified"
      timed_out <- phaseHandle "timed_out"

      let viewNotifySet = maybe Nothing (\(_, _, ns, _) -> Just ns)

      setPhase init_rule $ \(HAEvent eid (RuleHook pid) _) -> do
        rg <- getLocalGraph
        let Just p = listToMaybe $
                [ p' | (prof :: M0.Profile) <- G.connectedTo Cluster Has rg
                , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
                , (node :: M0.Node) <- G.connectedTo fs M0.IsParentOf rg
                , (p' :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
                ]
            servs :: [M0.Service]
            servs = G.connectedTo p M0.IsParentOf rg
        applyStateChanges [stateSet p M0.PSOffline]
        let notifySet = stateSet p M0.PSOffline : map (\s -> stateSet s M0.SSOffline) servs
            meroSet = Note (M0.fid p) M0_NC_FAILED : map (\s -> Note (M0.fid s) M0_NC_FAILED) servs
        put Local $ Just (eid, pid, notifySet, meroSet)
        switch [notified, timeout 15 timed_out]

      setPhaseAllNotified notified viewNotifySet $ do
        Just (eid, pid, _, meroSet) <- get Local
        phaseLog "info" $ "All notified"
        liftProcess . usend pid $ Set meroSet
        messageProcessed eid

      directly timed_out $ do
        Just (eid, _, _, _) <- get Local
        phaseLog "warn" $ "Notify timed out"
        messageProcessed eid

      start init_rule Nothing