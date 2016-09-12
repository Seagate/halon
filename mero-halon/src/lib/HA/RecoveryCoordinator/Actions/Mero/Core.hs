{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE LambdaCase                 #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--

module HA.RecoveryCoordinator.Actions.Mero.Core
  ( -- * Graph manipulation
    newFidSeq
  , newFidSeqRC
  , newFid
  , newFidRC
  , uniquePVerCounter
  , mkVirtualFid
  , getM0Globals
  , loadMeroGlobals
    -- * Mero actions execution
    -- $execution-model
  , LiftRC
  , mkUnliftProcess
    -- ** Action Runners
  , liftM0RC
  , withM0RC
  , m0synchronously
  , m0asynchronously
  , m0asynchronously_
    -- * Mero Worker
    -- $mero-worker
  , halonRCMeroWorkerLabel
  , createMeroWorker
  , tryCloseMeroWorker
  ) where

import HA.RecoveryCoordinator.Actions.Core
import qualified HA.ResourceGraph as G
import HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import HA.Services.Mero
import HA.Service (serviceLabel)

import Mero.ConfC ( Fid(..) )
import Mero.M0Worker

import Control.Distributed.Process
  ( getSelfPid
  , register
  , unregister
  , monitor
  , receiveWait
  , receiveTimeout
  , matchIf
  , kill
  , link
  , spawnLocal
  , whereis
  , Process
  , ProcessMonitorNotification(..)
  )
import qualified Control.Distributed.Process.Internal.Types as DI
import Control.Monad.IO.Class
import Control.Monad.Catch (SomeException, finally, try, bracket)
import Control.Monad.Trans.Reader (ask)
import Control.Concurrent.MVar
import Data.Bits (setBit)
import Data.Maybe (listToMaybe)
import Data.Functor (void)
import Data.Foldable
import Data.Proxy
import Data.Word ( Word64, Word32 )

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

uniquePVerCounter :: G.Graph -> (Word32, G.Graph)
uniquePVerCounter rg = case G.connectedTo Cluster Has rg of
   [] -> (0, G.connect Cluster Has (M0.PVerCounter 0) rg)
   ((M0.PVerCounter i):_) -> (i+1, G.connectUnique Cluster Has (M0.PVerCounter (i+1)) rg)

mkVirtualFid :: Fid -> Fid
mkVirtualFid (Fid container key) = Fid (setBit container (63-9)) key

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

--------------------------------------------------------------------------------
-- Mero actions execution
--------------------------------------------------------------------------------
-- $execution-model
--
-- For the commands that are required to be used in mero thread (mero-commands)
-- Recovery coordinator is using dedicated thread contolled by MeroWorker (see
-- mero worker). This is done in order to not block global mero thread.
--
-- All mero calls are scheduled in the queue, so it's guaranteed that order will
-- be preserved and actions will not overlap. However calls may be synchronious
-- or asynchronous in a sence that if they block Recovery Coordinator or not.
--
--   * [synchronous call] - low overhead call to mero thread, this call avoids
--      creation of the new helper threads and results serialization. However
--      RC thread will be blocked until call will exit. This call doesn't
--      require creation on additional phases and can be executed in 'PhaseM'
--      directly. Synchronous calls rethrow  possible exceptions as-is in the
--      RC thread.
--
--      Synchronous calls should be used only for the fast non-blocking calls.
--
--   * [asynchronous calls] - higher overhead calls to mero thread. Such calls
--      create helper D-P Process that will handle reply from mero and re-send
--      it to RC, so serialization is used. In order to handle reply additional
--      phase have to be introduced.
--
--      Asynchronous calls can be used for any kind of calls but at a cost of
--      performance and mainly maintenance and code support overhead.
--
--  As all calls are queued it's imporant that using synchronous call after
--  any asynchronous call will block RC thread until previous async call will
--  exit.
--
--  @
--  m0asynchronous >> m0asynchronous
--  @
--
--  will immediately exit and notifications will be received in the future point
--  of time.
--
--  @
--  m0asynchronous >> m0synchronous
--  @
--
--  will block RC thread until both async and sync actions will be executed.
--  This means that finalizers should be asynchronous for the additonal safety,
--  see 'm0asynchronous_'.

-- | Synchronously run the given computation in the m0 thread dedicated to the RC.
--
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
--    m0synchronously lift $ someOperationThatShouldBeRunningInM0Thread
-- @@@
withM0RC :: (LiftRC -> PhaseM LoopState l b)
         -> PhaseM LoopState l b
withM0RC f = getStorageRC >>= \case
  Nothing -> do mworker <- createMeroWorker
                case mworker of
                  Nothing -> error "No worker loaded."
                  Just w  -> f (LiftRC w)
  Just w  -> liftProcess (whereis halonRCMeroWorkerLabel) >>= \case
               Nothing -> do deleteStorageRC (Proxy :: Proxy M0Worker)
                             withM0RC f
               Just _  -> f (LiftRC w)


-- | Create a highly unsafe function that can run process state in
-- *any* IO, only different 'sends' are safe to be run in such thread.
mkUnliftProcess :: PhaseM LoopState l (Process a -> IO a)
mkUnliftProcess = do
  lproc <- liftProcess $ DI.Process ask
  return $ DI.runLocalProcess lproc

-- | Handle that allow to lift 'IO' operations into 'PhaseM'. Actions will be
-- running in mero thread associated with Recovery Coordinator.
data LiftRC = LiftRC M0Worker

-- XXX introduce m0now modifier, modifier should create new thread
-- if current one is running some actions.

-- | Use 'LiftRC' to action that require to be run in mero thread synchronously.
-- RC thread will be blocked until result will be received.
m0synchronously :: LiftRC
                -> IO a
                -> PhaseM LoopState l a
m0synchronously (LiftRC w) = runOnM0Worker w

-- | Run action asynchronously. RC thread will not be blocked and will
-- immediately exit. All calls that will be run after 'm0asynchronously' will
-- be scheduled to run after the call.
m0asynchronously :: LiftRC
                 -> (Either SomeException a -> Process ())
                 -> IO a
                 -> PhaseM LoopState l ()
m0asynchronously (LiftRC w) onExecution action = liftProcess $ do
  lproc <- DI.Process ask
  liftIO $ queueM0Worker w $ do
    try action >>= DI.runLocalProcess lproc . onExecution

-- | More efficient version of the 'm0asynchronously', that does
-- not wait for result. This method is more efficient than
-- 'm0synchronously' but like 'm0asynchronously' does not propagate exceptions
-- to RC thread.
m0asynchronously_ :: LiftRC
                  -> IO a
                  -> PhaseM LoopState l ()
m0asynchronously_ (LiftRC w) = liftIO . queueM0Worker w . void

--------------------------------------------------------------------------------
-- Mero actions execution
--------------------------------------------------------------------------------
-- TODO rename to mero-angel :)

-- $mero-worker
-- Dedicated thread that is running together with RC, and controls mero thread
-- decidated to RC actions.

-- | Label of the mero worker.
halonRCMeroWorkerLabel :: String
halonRCMeroWorkerLabel = "halon:rc-mero-worker"

-- | Creates a worker if m0d service is running on the node.
-- This method registers accompaniment process "halon:rc-mero-worker"
createMeroWorker :: PhaseM LoopState l (Maybe M0Worker)
createMeroWorker = do
  pid <- liftProcess getSelfPid
  lprocess <- liftProcess $ whereis $ serviceLabel m0d
  case lprocess of
    Just{} -> do
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
    _ -> do
      phaseLog "error" "Mero service is not running on the node, can't create worker"
      return Nothing

-- | Try to close mero worker process if it's running.
-- Do nothing if no process is registered. Blocks until process or for 8 seconds
-- if process didn't exit first.
tryCloseMeroWorker :: Process ()
tryCloseMeroWorker = do
  mpid <- whereis halonRCMeroWorkerLabel
  forM_ mpid $ \pid -> do
    unregister halonRCMeroWorkerLabel
    mon <- monitor pid
    kill pid "RC exit"
    receiveTimeout (8*1000000)
      [matchIf (\(ProcessMonitorNotification mref _ _) -> mref == mon)
               (\_ -> return ())
      ]
