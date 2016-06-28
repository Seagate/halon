{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleContexts #-}
-- |
-- Copyright:  (C) 2015 Seagate Technology Limited.
--
-- Helpers that simplifies creation of the long running processes
module HA.RecoveryCoordinator.Actions.Job
   ( -- * Process
     Job(..)
   , mkJobRule
     -- * Predefined accessor fields.
   , fldUUID
   ) where

import HA.EventQueue.Types
import HA.RecoveryCoordinator.Actions.Core

import Control.Distributed.Process (say)
import Control.Distributed.Process.Serializable
import Control.Lens

import Data.Foldable (for_)
import Data.Proxy
import qualified Data.Set as Set
import Data.Vinyl

import Network.CEP

-- | Process handle. Process is a long running rule
-- that is triggered when some @input@ event is received
-- and emits @output@ event as a result of it's run.
newtype Job input output = Job String


type FldUUID = '("uuid", Maybe UUID)
fldUUID :: Proxy FldUUID
fldUUID = Proxy

-- | Create rule for a given process. This is a helper
-- method that removes some boilerplate that is needed
-- in order to define such rule
--
-- It's not legitimate to call 'Network.CEP.stop' inside
-- this @body@.
mkJobRule :: forall input output l args s .
   ( FldUUID ∈ l, '("request", Maybe input) ∈ l, '("reply", Maybe output) ∈ l
   , Serializable input, Serializable output, Ord input,Show input, s ~ Rec ElField l)
   => Job input output  -- ^ Process name.
   -> s
   -> (Jump PhaseHandle -> RuleM LoopState s (input -> PhaseM LoopState s (Maybe [Jump PhaseHandle])))
   -- ^ Rule body, takes final handle as paramter, returns an action  used to
   -- decide how to process rule
   -> Specification LoopState ()
mkJobRule (Job name)
              args
              body = define name $ do
    request <- phaseHandle "request"
    finish  <- phaseHandle "finish"
    end     <- phaseHandle "end"

    check_input <- body finish

    setPhase request $ \(HAEvent eid input _) -> do
      isRunning <- memberStorageSetRC input
      if isRunning
      then do
         phaseLog "info" $ "Process " ++ name ++ " is already running for " ++ show input
         messageProcessed eid
      else
        check_input input >>= \case
          Nothing -> messageProcessed eid
          Just next -> do
            insertStorageSetRC input
            fork CopyNewerBuffer $ do
              modify Local $ rlens fldRequest .~ (Field $ Just input)
              modify Local $ rlens fldUUID    .~ (Field $ Just eid)
              switch next

    directly finish $ do  -- XXX: use rule finalier, when implemented
      state  <- get Local
      let uuid = state ^. rlens fldUUID
          req  = state ^. rlens fldRequest
          rep  = state ^. rlens fldReply
      for_ (getField rep) notify
      for_ (getField req) deleteStorageSetRC
      for_ (getField uuid) messageProcessed
      continue end

    directly end stop

    startFork request args
  where
    fldRequest :: Proxy '("request", Maybe input)
    fldRequest = Proxy
    fldReply :: Proxy '("reply", Maybe output)
    fldReply = Proxy
