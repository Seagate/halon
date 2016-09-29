{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
-- |
-- Copyright:  (C) 2015 Seagate Technology Limited.
--
-- Helpers that simplifies creation of the long running processes
module HA.RecoveryCoordinator.Job.Actions
   ( -- * Process
     Job(..)
   , mkJobRule
   , startJob
   , ListenerId
   , FldListenerId
   , fldListenerId
   ) where

import HA.RecoveryCoordinator.Job.Events
import HA.RecoveryCoordinator.Job.Internal

import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Core

import Control.Distributed.Process.Serializable
import Control.Lens
import Control.Monad (unless, join)
import Control.Monad.IO.Class (liftIO)

import Data.Binary (Binary)
import Data.Foldable (for_)
import Data.Traversable (for)
import Data.Typeable (Typeable)
import Data.Proxy
import Data.Vinyl
import qualified Data.UUID.V4 as UUID

import Network.CEP

type FldListenerId = '("listenerId", Maybe ListenerId)

fldListenerId :: Proxy FldListenerId
fldListenerId = Proxy

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
   , Serializable input, Serializable output, Ord input,Show input, s ~ Rec ElField l, Show output)
   => Job input output  -- ^ Process name.
   -> s
   -> (Jump PhaseHandle -> RuleM LoopState s (input -> PhaseM LoopState s (Maybe [Jump PhaseHandle])))
   -- ^ Rule body, takes final handle as paramter, returns an action  used to
   -- decide how to process rule
   -> Definitions LoopState ()
mkJobRule (Job name)
              args
              body = define name $ do
    request         <- phaseHandle $ name ++ " -> request"
    indexed_request <- phaseHandle $ name ++ " -> indexed request"
    finish          <- phaseHandle $ name ++ " -> finish"
    end             <- phaseHandle $ name ++ " -> end"

    check_input <- body finish

    let processRequest eid input listeners = do
          isRunning <- memberStorageMapRC pJD input
          if isRunning
          then do
            phaseLog "info" $ "Job is already running"
            phaseLog "input" $ show input
            if null listeners
            then do phaseLog "action" "Mark message processed"
                    messageProcessed eid
            else do phaseLog "action" "Adding listeners"
                    insertWithStorageMapRC (mappend) input (JobDescription [eid] listeners)
          else do
              phaseLog "request" $ show input
              modify Local $ rlens fldRequest .~ (Field $ Just input)
              check_input input >>= \case
                Nothing -> do
                  phaseLog "action" "Ignoring message due to rule filter."
                  messageProcessed eid
                Just next -> do
                  phaseLog "action" "Starting execution."
                  insertWithStorageMapRC (mappend) input (JobDescription [eid] listeners)
                  fork CopyNewerBuffer $ switch next


    setPhase request $ \(HAEvent eid input _) -> processRequest eid input []
    setPhase indexed_request $ \(HAEvent eid (JobStartRequest uuid input) _) ->
       processRequest eid input [uuid]

    directly finish $ do  -- XXX: use rule finalier, when implemented
      state <- get Local
      let req  = state ^. rlens fldRequest
          rep  = state ^. rlens fldReply
      phaseLog "request" $ maybe "N/A" show (getField req)
      phaseLog "reply"   $ show (getField rep)
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

startJob :: (Typeable r, Binary r) => r -> PhaseM LoopState l ListenerId
startJob request = do
  l <- ListenerId <$> liftIO UUID.nextRandom
  promulgateRC $ JobStartRequest l request
  return l
