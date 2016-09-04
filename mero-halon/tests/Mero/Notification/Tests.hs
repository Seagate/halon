-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
module Mero.Notification.Tests
   ( tests
   ) where

import Control.Concurrent.STM
import Control.Distributed.Process
import Control.Distributed.Process.Scheduler
import Control.Monad (when)
import Mero.ConfC hiding (Process)
import Mero.Notification
import qualified HA.Resources.Mero.Note as M0
import Mero.Notification.HAState
import Network.Transport
import HA.RecoveryCoordinator.Helpers

import Test.Tasty
import Test.Tasty.HUnit (assertEqual, testCase, assertFailure)

tests :: Transport -> TestTree
tests transport = testGroup "mero-notification-worker"
   [ testCase "testNotificationWorker" $ testNotificationWorker transport
   ]

testNotificationWorker :: Transport -> IO ()
testNotificationWorker transport = runDefaultTest transport $ do
     notificationChannel <- liftIO $ newTChanIO
     let fid1 = Fid 0 1
     self   <- getSelfPid
     pid <- spawnLocal $ notificationWorker notificationChannel
                                          (usend self)

     -- send message and it should be delivered.
     liftIO $ atomically $ writeTChan notificationChannel [Note fid1 M0.M0_NC_TRANSIENT]
     mnotes <- expectTimeout (pendingInterval + pendingInterval `div` 2)
     liftIO $ case mnotes of
       Nothing -> assertFailure "sent message was not delivered."
       Just [Note xfid1 st] -> do assertEqual "fid is correct" fid1 xfid1
                                  assertEqual "state should be transient" M0.M0_NC_TRANSIENT st
       Just ns -> assertFailure $ "too many messages were delivered: " ++ show ns
     mnotes2 <- expectTimeout (2*sentInterval) :: Process (Maybe Note)
     liftIO $ assertEqual "only one message was delivered" Nothing mnotes2

     -- send 2 messages that are similar
     liftIO $ atomically $ writeTChan notificationChannel [Note fid1 M0.M0_NC_TRANSIENT]
     when schedulerIsEnabled $ usend pid ()
     liftIO $ atomically $ writeTChan notificationChannel [Note fid1 M0.M0_NC_TRANSIENT]
     when schedulerIsEnabled $ usend pid ()
     mnotes3 <- expectTimeout (pendingInterval+pendingInterval `div` 2)
     liftIO $ case mnotes3 of
       Nothing -> assertFailure "sent message was not delivered."
       Just [Note xfid1 st] -> do assertEqual "fid is correct" fid1 xfid1
                                  assertEqual "state should be transient" M0.M0_NC_TRANSIENT st
       Just ns -> assertFailure $ "too many messages were delivered: " ++ show ns
     mnotes4 <- expectTimeout (sentInterval + pendingInterval) :: Process (Maybe Note)
     liftIO $ assertEqual "only one message was delivered" Nothing mnotes4

     -- send and cancel messages
     liftIO $ atomically $ writeTChan notificationChannel [Note fid1 M0.M0_NC_TRANSIENT]
     when schedulerIsEnabled $ usend pid ()
     liftIO $ atomically $ writeTChan notificationChannel [Note fid1 M0.M0_NC_ONLINE]
     when schedulerIsEnabled $ usend pid ()
     _mnotes5 <- expectTimeout (pendingInterval+pendingInterval `div` 2) :: Process (Maybe Note)
     liftIO $ assertEqual "only one message was delivered" Nothing mnotes4
     _ <- receiveTimeout (cancelledInterval) [] :: Process (Maybe ())

     -- filter out after send
     liftIO $ atomically $ writeTChan notificationChannel [Note fid1 M0.M0_NC_TRANSIENT]
     when schedulerIsEnabled $ usend pid ()
     mnotes6 <- expectTimeout (pendingInterval+pendingInterval `div` 2)
     liftIO $ case mnotes6 of
       Nothing -> assertFailure "sent message was not delivered."
       Just [Note xfid1 st] -> do assertEqual "fid is correct" fid1 xfid1
                                  assertEqual "state should be transient" M0.M0_NC_TRANSIENT st
       Just ns -> assertFailure $ "too many messages were delivered: " ++ show ns
     liftIO $ atomically $ writeTChan notificationChannel [Note fid1 M0.M0_NC_TRANSIENT]
     when schedulerIsEnabled $ usend pid ()
     mnotes7 <- expectTimeout (sentInterval + pendingInterval) :: Process (Maybe Note)
     liftIO $ assertEqual "only one message was delivered" Nothing mnotes7
