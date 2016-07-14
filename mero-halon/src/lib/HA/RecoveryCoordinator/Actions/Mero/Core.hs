-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE LambdaCase                 #-}

module HA.RecoveryCoordinator.Actions.Mero.Core where

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Service
import qualified HA.ResourceGraph as G
import HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import qualified HA.Resources as R
import HA.Services.Mero
import HA.Service

import Mero.ConfC ( Fid )
import Mero.M0Worker

import Control.Applicative (liftA2)
import Control.Distributed.Process
  ( getSelfNode
  , getSelfPid
  , register
  , unregister
  , monitor
  , receiveWait
  , matchIf
  , kill
  , link
  , spawnLocal
  , whereis
  , Process
  , ProcessMonitorNotification(..)
  )
import Control.Monad.IO.Class
import Control.Monad.Catch (finally)
import Data.Maybe (listToMaybe)
import Data.Foldable
import Data.Proxy
import Data.Word ( Word64 )

import Network.CEP

import Prelude hiding (id)

newFidSeq :: G.Graph -> (Word64, G.Graph)
newFidSeq rg = case G.connectedTo Cluster Has rg of
    ((M0.FidSeq w):_) -> go w
    [] -> go 0
  where
    go w = let w' = w + 1
               rg' = G.connectUniqueFrom Cluster Has (M0.FidSeq w') $ rg
           in (w, rg')

-- | Atomically fetch a FID sequence number of increment the sequence count.
newFidSeqRC :: PhaseM LoopState l Word64
newFidSeqRC = do
  rg <- getLocalGraph
  let (w, rg') = newFidSeq rg
  putLocalGraph rg'
  return w

newFid :: M0.ConfObj a => Proxy a -> G.Graph -> (Fid, G.Graph)
newFid p rg = (M0.fidInit p 1 w, rg') where
  (w, rg') = newFidSeq rg

newFidRC :: M0.ConfObj a => Proxy a -> PhaseM LoopState l Fid
newFidRC p = M0.fidInit p 1 <$> newFidSeqRC

--------------------------------------------------------------------------------
-- Core configuration
--------------------------------------------------------------------------------

getM0Globals :: PhaseM LoopState l (Maybe CI.M0Globals)
getM0Globals = getLocalGraph >>= \rg -> do
  phaseLog "rg-query" $ "Looking for Mero globals."
  return . listToMaybe
    $ G.connectedTo Cluster Has rg

-- | Load Mero global data into the graph
loadMeroGlobals :: CI.M0Globals
                -> PhaseM LoopState l ()
loadMeroGlobals g = modifyLocalGraph $ return . G.connect Cluster Has g

-- | Run the given computation in the m0 thread dedicated to the RC.
--
-- Some operations the RC submits cannot use the global m0 worker ('liftGlobalM0') because
-- they would require grabbing the global m0 worker a second time thus blocking the application.
-- Currently, these are spiel operations which use the notification interface before returning
-- control to the caller.
-- This call will return Nothing if no RC worker was created.
liftM0RC :: IO a -> PhaseM LoopState l (Maybe a)
liftM0RC task = getStorageRC >>= traverse (\worker -> runOnM0Worker worker task)

-- | A operation with guarantee that mero worker is available. This call provide
-- an operation for running 'IO' in m0 thread.
--
-- If worker is not yet ready it will be created.
--
-- @@@
-- withM0RC $ \lift ->
--    lift $ someOperationThatShouldBeRunningInM0Thread
-- @@@
withM0RC :: ((forall a . IO a -> PhaseM LoopState l a) -> PhaseM LoopState l b)
         -> PhaseM LoopState l b
withM0RC f = getStorageRC >>= \case
  Nothing -> do mworker <- createMeroWorker
                case mworker of
                  Nothing -> error "No worker loaded."
                  Just w  -> f (runOnM0Worker w)
  Just w  -> liftProcess (whereis halonRCMeroWorkerLabel) >>= \case
               Nothing -> do deleteStorageRC (Proxy :: Proxy M0Worker)
                             withM0RC f
               Just _  -> f (runOnM0Worker w)

halonRCMeroWorkerLabel :: String
halonRCMeroWorkerLabel = "halon:rc-mero-worker"

-- | Creates a worker if m0d service is running on the node.
-- This method registers accompaniment process "halon:rc-mero-worker"
createMeroWorker :: PhaseM LoopState l (Maybe M0Worker)
createMeroWorker = do
  pid <- liftProcess getSelfPid
  node <- liftProcess getSelfNode
  mprocess <- lookupRunningService (R.Node node) m0d
  lprocess <- liftProcess $
    whereis $ "service." ++ ((\(ServiceName s) -> s) meroServiceName)
  case liftA2 (,) lprocess mprocess of
    Just (lproc, ServiceProcess proc)
      | proc == lproc -> do
      worker <- liftIO newM0Worker
      liftProcess $ do
        whereis halonRCMeroWorkerLabel >>= \case
          Nothing -> return ()
          Just q  -> do mref <- monitor q
                        kill q "exit"
                        receiveWait [ matchIf (\(ProcessMonitorNotification m _ _) -> m == mref)
                                              $ \_ -> return ()]
        wrkPid <- liftProcess $ spawnLocal $ do
          link pid
          finally (receiveWait [])
                  (do sayRC "worker-closed"
                      liftGlobalM0 $ terminateM0Worker worker)
        register halonRCMeroWorkerLabel wrkPid
      putStorageRC worker
      return (Just worker)
    Nothing -> do
      phaseLog "error" "Mero service is not running on the node, can't create worker"
      return Nothing

-- | Try to close mero worker process if it's running.
-- Do nothing if no process is registered. Blocks until process exit otherwise.
tryCloseMeroWorker :: Process ()
tryCloseMeroWorker = do
  mpid <- whereis halonRCMeroWorkerLabel
  forM_ mpid $ \pid -> do
    unregister halonRCMeroWorkerLabel
    mon <- monitor pid
    kill pid "RC exit"
    receiveWait [matchIf (\(ProcessMonitorNotification mref _ _) -> mref == mon)
                         (\_ -> return ())
                ]
