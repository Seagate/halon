{-# LANGUAGE OverloadedStrings #-}
-- |
-- Module    : HA.Test.InternalStateChanges
-- Copyright : (C) 2016-2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Exercise the internal state change mechanism
module HA.Test.InternalStateChanges (mkTests) where

import           Control.Distributed.Process hiding (bracket)
import           Control.Exception as E
import           Data.List (nub, sort)
import           Data.Maybe (listToMaybe, mapMaybe)
import           Data.Typeable
import           HA.RecoveryCoordinator.Mero
import           HA.RecoveryCoordinator.Mero.State
import qualified HA.RecoveryCoordinator.Mero.Transitions as Tr
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.Replicator hiding (getState)
import qualified HA.ResourceGraph as G
import           HA.Resources
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note
import qualified Helper.Runner as H
import           Mero.Notification
import           Network.AMQP
import           Network.CEP
import           Network.Transport
import           Test.Framework

mkTests :: (Typeable g, RGroup g) => Proxy g -> IO (Transport -> [TestTree])
mkTests pg = do
  ex <- E.try $ Network.AMQP.openConnection "localhost" "/" "guest" "guest"
  case ex of
    Left (e::AMQPException) -> return $ \_->
      [testSuccess "InternalStateChange tests" $ error $ "RabbitMQ error: " ++ show e]
    Right x -> do
      closeConnection x
      return $ \t ->
        [ testSuccess "stateCascade" $
           stateCascade t pg
        ,testSuccess "failureVector" $
           failvecCascade t pg
        ]

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
stateCascade t pg = do
  tos <- H.mkDefaultTestOptions
  let tos' = tos { H._to_run_sspl = False }
  H.run' t pg [rule] tos' test'
  where
    test' :: H.TestSetup -> Process ()
    test' ts = do
      self <- getSelfPid
      usend (H._ts_rc ts) $ H.RuleHook self
      True <- expect
      return ()

    rule :: Definitions RC ()
    rule = defineSimple "stateCascadeTest" $ \(H.RuleHook pid) -> do
      rg <- getLocalGraph
      let Just p = listToMaybe $
              [ proc | Just (prof :: M0.Profile_XXX3) <- [G.connectedTo Cluster Has rg]
              , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
              , (rack :: M0.Rack) <- G.connectedTo fs M0.IsParentOf rg
              , (encl :: M0.Enclosure) <- G.connectedTo rack M0.IsParentOf rg
              , (ctrl :: M0.Controller) <- G.connectedTo encl M0.IsParentOf rg
              , Just (node :: M0.Node) <- [G.connectedFrom M0.IsOnHardware ctrl rg]
              , (proc :: M0.Process) <- G.connectedTo node M0.IsParentOf rg
              ]
          srvs = G.connectedTo p M0.IsParentOf rg :: [M0.Service]
      _ <- applyStateChanges [stateSet p Tr.processStarting]
      rg' <- getLocalGraph

      let allOK = getState p rg'  == M0.PSStarting
                  && all (\s -> getState s rg' == M0.SSStarting) srvs
      liftProcess $ usend pid allOK

failvecCascade :: (Typeable g, RGroup g) => Transport -> Proxy g -> IO ()
failvecCascade t pg = do
  tos <- H.mkDefaultTestOptions
  let tos' = tos { H._to_run_sspl = False }
  H.run' t pg [rule] tos' test'
  where
    test' :: H.TestSetup -> Process ()
    test' ts = do
      self <- getSelfPid
      usend (H._ts_rc ts) $ H.RuleHook self
      expect >>= maybe (return ()) fail

    rule :: Definitions RC ()
    rule = defineSimple "stateCascadeTest" $ \(H.RuleHook pid) -> do
      Log.rcLog' Log.DEBUG ("Set hooks." :: String)
      rg <- getLocalGraph
      let d0:d1:_ =
              [ disk | Just (prof :: M0.Profile_XXX3) <- [G.connectedTo Cluster Has rg]
              , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg
              , (rack :: M0.Rack) <- G.connectedTo fs M0.IsParentOf rg
              , (enclosure :: M0.Enclosure) <- G.connectedTo rack M0.IsParentOf rg
              , (controller :: M0.Controller) <- G.connectedTo enclosure M0.IsParentOf rg
              , (disk :: M0.Disk) <- G.connectedTo controller M0.IsParentOf rg
              ]
          disks = [d0, d1]
      _ <- applyStateChanges $ map (`stateSet` Tr.diskFailed) disks
      rg' <- getLocalGraph

      let pools =
              [ pool | Just (prof :: M0.Profile_XXX3) <- [G.connectedTo Cluster Has rg']
              , (fs :: M0.Filesystem) <- G.connectedTo prof M0.IsParentOf rg'
              , (pool :: M0.Pool_XXX3) <- G.connectedTo fs M0.IsParentOf rg'
              , (pver :: M0.PVer) <- G.connectedTo pool M0.IsParentOf rg'
              , M0.fid pool /= M0.f_mdpool_fid fs
              , M0.fid pver /= M0.f_imeta_fid fs
              ]
          mvs :: [M0.Disk]
          mvs = nub . sort . concat $ mapMaybe
                (\pl -> (\(M0.DiskFailureVector v) -> v) <$> G.connectedTo pl Has rg')
                pools
          allOK = mvs == sort disks
                  && getState d0 rg' == M0.SDSFailed
                  && getState d1 rg' == M0.SDSFailed
          msg = if allOK
                then Nothing
                else Just $ show (mvs, disks
                                 , map (\d -> getState d rg') mvs
                                 , map (\d -> getState d rg') disks)
      liftProcess $ usend pid msg
