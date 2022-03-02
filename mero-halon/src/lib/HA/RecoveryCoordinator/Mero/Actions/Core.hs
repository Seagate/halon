{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
-- |
-- Module    : HA.RecoveryCoordinator.Mero.Actions.Core
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module HA.RecoveryCoordinator.Mero.Actions.Core
  ( -- * Graph manipulation
    newFid
  , newFidRC
  , uniquePVerCounter
  , getM0Globals
  , loadMeroGlobals
    -- * Mero actions execution
    -- $execution-model
  , LiftRC
  , mkLiftRC
  , mkUnliftProcess
    -- ** Action Runners
  , liftM0RC
  , withM0RC
  , m0synchronously
  , m0asynchronously
  , m0asynchronously_
  ) where

import           Control.Distributed.Process (Process)
import qualified Control.Distributed.Process.Internal.Types as DI
import           Control.Monad.Catch (SomeException, try, throwM)
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Reader (ask)
import           Data.Functor (void)
import           Data.Proxy
import           Data.Word (Word32, Word64)
import           HA.RecoveryCoordinator.Mero.Events
import           HA.RecoveryCoordinator.RC.Actions
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import qualified HA.ResourceGraph as G
import           HA.Resources (Cluster(..), Has(..))
import qualified HA.Resources.Castor.Initial as CI
import qualified HA.Resources.Mero as M0
import           HA.Services.Mero (getM0Worker)
import           Mero.ConfC (Fid)
import           Mero.M0Worker
import           Network.CEP

newFidSeq :: G.Graph -> (Word64, G.Graph)
newFidSeq rg = case G.connectedTo Cluster Has rg of
    Just (M0.FidSeq w) -> go w
    Nothing -> go 0
  where
    go w = let w' = w + 1
               rg' = G.connect Cluster Has (M0.FidSeq w') $ rg
           in (w, rg')

-- | Atomically fetch a FID sequence number of increment the sequence count.
newFidSeqRC :: PhaseM RC l Word64
newFidSeqRC = do
  rg <- getGraph
  let (w, rg') = newFidSeq rg
  putGraph rg'
  return w

-- | Create a new 'Fid' for the given 'M0.ConfObj' type.
newFid :: M0.ConfObj a => Proxy a -> G.Graph -> (Fid, G.Graph)
newFid p rg = (M0.fidInit p 1 w, rg') where
  (w, rg') = newFidSeq rg

-- | Like 'newFid' but graph is taken from phase global state.
newFidRC :: M0.ConfObj a => Proxy a -> PhaseM RC l Fid
newFidRC p = M0.fidInit p 1 <$> newFidSeqRC

-- | Generate a unique pool version number.
uniquePVerCounter :: G.Graph -> (Word32, G.Graph)
uniquePVerCounter rg = case G.connectedTo Cluster Has rg of
   Nothing -> (0, G.connect Cluster Has (M0.PVerCounter 0) rg)
   Just (M0.PVerCounter !i) ->
     (i+1, G.connect Cluster Has (M0.PVerCounter (i+1)) rg)

--------------------------------------------------------------------------------
-- Core configuration
--------------------------------------------------------------------------------

-- | Retrieve 'CI.M0Globals' from the RG.
getM0Globals :: PhaseM RC l (Maybe CI.M0Globals)
getM0Globals = getGraph >>= \rg -> do
  Log.rcLog' Log.TRACE $ "Looking for Mero globals."
  return $ G.connectedTo Cluster Has rg

-- | Load Mero global data into the graph
loadMeroGlobals :: CI.M0Globals -> PhaseM RC l ()
loadMeroGlobals g = modifyGraphM $ return . G.connect Cluster Has g

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
liftM0RC :: IO a -> PhaseM RC l (Maybe a)
liftM0RC task = liftIO getM0Worker >>= traverse (\worker -> runOnM0Worker worker task)

-- | A operation with guarantee that mero worker is available. This call provide
-- an operation for running 'IO' in m0 thread.
--
-- If worker is not yet ready it will be created.
--
-- @@@
-- withM0RC $ \lift ->
--    m0synchronously lift $ someOperationThatShouldBeRunningInM0Thread
-- @@@
withM0RC :: (LiftRC -> PhaseM RC l b)
         -> PhaseM RC l b
withM0RC f = liftIO getM0Worker >>= \case
  Nothing -> throwM WorkerIsNotAvailable
  Just w  -> f (LiftRC w)

-- | Create a highly unsafe function that can run process state in
-- *any* IO, only different 'sends' are safe to be run in such thread.
mkUnliftProcess :: PhaseM RC l (Process a -> IO a)
mkUnliftProcess = do
  lproc <- liftProcess $ DI.Process ask
  return $ DI.runLocalProcess lproc

-- | Handle that allow to lift 'IO' operations into 'PhaseM'. Actions will be
-- running in mero thread associated with Recovery Coordinator.
data LiftRC = LiftRC M0Worker

-- | Wrap known worker into lift  handle.
mkLiftRC :: M0Worker -> LiftRC
mkLiftRC = LiftRC

-- XXX introduce m0now modifier, modifier should create new thread
-- if current one is running some actions.

-- | Use 'LiftRC' to action that require to be run in mero thread synchronously.
-- RC thread will be blocked until result will be received.
m0synchronously :: LiftRC
                -> IO a
                -> PhaseM RC l a
m0synchronously (LiftRC w) = runOnM0Worker w

-- | Run action asynchronously. RC thread will not be blocked and will
-- immediately exit. All calls that will be run after 'm0asynchronously' will
-- be scheduled to run after the call.
m0asynchronously :: LiftRC
                 -> (Either SomeException a -> Process ())
                 -> IO a
                 -> PhaseM RC l ()
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
                  -> PhaseM RC l ()
m0asynchronously_ (LiftRC w) = liftIO . queueM0Worker w . void
