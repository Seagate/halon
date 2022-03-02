{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
-- |
-- Copyright:  (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
--
-- Helpers that simplifies creation of the long running processes
module HA.RecoveryCoordinator.Job.Actions
   ( -- * Process
     Job(..)
   , JobHandle(..)
   , mkJobRule
   , startJob
   , startJobEQ
   , ListenerId
   , FldListenerId
   , fldListenerId
   ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Lens
import           Control.Monad (unless, join, void)
import           Control.Monad.IO.Class (liftIO)
import           Data.Foldable (for_)
import           Data.Proxy
import           Data.Traversable (for)
import           Data.Typeable (Typeable)
import qualified Data.UUID.V4 as UUID
import           Data.Vinyl
import           HA.EventQueue
import qualified HA.RecoveryCoordinator.RC.Actions.Log as Log
import           HA.RecoveryCoordinator.RC.Actions.Core
import           HA.RecoveryCoordinator.Job.Events
import           HA.RecoveryCoordinator.Job.Internal
import           HA.SafeCopy
import           Network.CEP

-- | Alias for 'ListenerId' field type.
type FldListenerId = '("listenerId", Maybe ListenerId)

-- | Field used to store the ID of job listener.
fldListenerId :: Proxy FldListenerId
fldListenerId = Proxy

-- | Datatype that keeps all helper methods that are needed
-- for implementing rule.
data JobHandle s input = JobHandle
  { getJobRequest :: PhaseM RC s input
    -- ^ Helper to read request from the Local state
  , finishJob :: Jump PhaseHandle
    -- ^ Final state that should be reached by the end of the rule.
  }

-- | Process handle. Process is a long running rule
-- that is triggered when some @input@ event is received
-- and emits @output@ event as a result of it's run.
newtype Job input output = Job String

-- | Create rule for a given process. This is a helper
-- method that removes some boilerplate that is needed
-- in order to define such rule.
--
-- Job identity is completely determined by its input
-- event; for each event, only one instance of any job
-- may run. Note that this means that if we have two
-- distinct jobs that take the same input, only one of
-- them may run at any given time.
--
-- Note that also no other rules should fire on the
-- input, unless they do not mind that the event could
-- be deleted.
--
-- It's not legitimate to call 'Network.CEP.stop' inside
-- this @body@.
mkJobRule :: forall input output l s .
   ( '("request", Maybe input) ∈ l, '("reply", Maybe output) ∈ l
   , SafeCopy input, Serializable input, Serializable output
   , Ord input, Show input, s ~ Rec ElField l, Show output)
   => Job input output  -- ^ Process name.
   -> s
   -> (JobHandle s input -> RuleM RC s (input -> PhaseM RC s (Either String (output, [Jump PhaseHandle]))))
   -- ^ Rule body, takes final handle as parameter, returns an action used to
   -- decide how to process rule
   -> Definitions RC ()
mkJobRule (Job name) args body = define name $ do
    request         <- phaseHandle $ name ++ " -> request"
    indexed_request <- phaseHandle $ name ++ " -> indexed request"
    finish          <- phaseHandle $ name ++ " -> finish"
    end             <- phaseHandle $ name ++ " -> end"

    let getRequest = do
          state <- get Local
          let mreq = state ^. rlens fldRequest
          case getField mreq of
            Nothing -> do
              Log.rcLog' Log.ERROR ("No request found" :: String)
              continue finish
            Just req -> return req

    check_input <- body $ JobHandle getRequest finish

    let processRequest eid input listeners = do
          isRunning <- memberStorageMapRC pJD input
          if isRunning
          then do
            Log.rcLog' Log.DEBUG [ ("input"::String, show input)
                                 , ("info"::String,"already running"::String)
                                 ]
            if null listeners
            then do messageProcessed eid
            else do Log.rcLog' Log.DEBUG ("add listener"::String, show eid)
                    insertWithStorageMapRC (mappend) input (JobDescription [eid] listeners)
          else do
              modify Local $ rlens fldRequest . rfield .~ Just input
              check_input input >>= \case
                Left reason -> do
                  Log.rcLog' Log.DEBUG [ ("input"::String, show input)
                                       , ("action"::String, "Ignoring message due to rule filter" :: String)
                                       , ("reason"::String, reason)
                                       ]
                  messageProcessed eid
                Right (def, next) -> fork CopyNewerBuffer $ do
                  modify Local $ rlens fldReply . rfield .~ Just def
                  Log.tagContext Log.SM [ ("request", show request)
                                        , ("eid", show eid)
                                        , ("listeners", show listeners)
                                        ] Nothing
                  insertWithStorageMapRC (mappend) input (JobDescription [eid] listeners)
                  switch next

    setPhase request $ \(HAEvent eid input) -> processRequest eid input []
    setPhase indexed_request $ \(HAEvent eid (JobStartRequest uuid input)) ->
       processRequest eid input [uuid]

    directly finish $ do  -- XXX: use rule finalier, when implemented
      state <- get Local
      let req  = state ^. rlens fldRequest
          rep  = state ^. rlens fldReply
      Log.tagContext Log.SM [("reply"::String, show (getField rep))] Nothing
      Log.rcLog' Log.DEBUG ("Rule finished execution."::String)
      mdescription <- fmap join $ for (getField req) $ \input -> do
        x <- lookupStorageMapRC input
        deleteStorageMapRC pJD input
        return x
      for_ (getField rep) notify
      for_ mdescription $ \(JobDescription uuids listeners) -> do
         for_ uuids messageProcessed
         unless (null listeners) $ do
           for_ (getField rep) $ notify . JobFinished listeners
      continue end

    directly end stop

    startForks [request, indexed_request] args
  where
    pJD :: Proxy JobDescription
    pJD = Proxy
    fldRequest :: Proxy '("request", Maybe input)
    fldRequest = Proxy
    fldReply :: Proxy '("reply", Maybe output)
    fldReply = Proxy

-- | Like 'startJob' but allows the user to specify set of EQ nodes to
-- use. Blocking.
startJobEQ :: (MonadProcess m, Typeable r, SafeCopy r)
           => [NodeId] -> r -> m ListenerId
startJobEQ nids request = liftProcess $ do
  l <- ListenerId <$> liftIO UUID.nextRandom
  let wait = void (expect :: Process ProcessMonitorNotification)
  promulgateEQ nids (JobStartRequest l request) >>= \pid -> withMonitor pid wait
  return l

-- | Start a job using the given request. Returns a listener ID that
-- can be kept by the caller.
startJob :: (MonadProcess m, Typeable r, SafeCopy r) => r -> m ListenerId
startJob request = do
  l <- liftProcess $ ListenerId <$> liftIO UUID.nextRandom
  promulgateRC $ JobStartRequest l request
  return l
