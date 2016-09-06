-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Rules specific to drives in RAID arrays.
--

{-# LANGUAGE RecordWildCards #-}
module HA.RecoveryCoordinator.Castor.Drive.Rules.Raid
  ( rules
    -- * Individual rules exported
  , failed
  ) where

import HA.EventQueue.Types (HAEvent(..))
import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Castor.Drive.Events
  ( RaidUpdate(..)
  , ResetAttempt(..)
  , ResetFailure(..)
  , ResetSuccess(..)
  )
import HA.Resources (Node(..))
import HA.Services.SSPL.CEP (sendNodeCmd)
import HA.Services.SSPL.LL.Resources
  ( NodeCmd(..)
  , RaidCmd(..)
  )

import Control.Distributed.Process (liftIO)
import Control.Monad (void)

import qualified Data.Text as T
import Data.UUID.V4 (nextRandom)

import Network.CEP

-- | All rules exported by this module.
rules :: Definitions LoopState ()
rules = sequence_
  [ failed ]

-- | RAID device failure rule.
failed :: Definitions LoopState ()
failed = define "castor::drive::raid::failed" $ do

  raid_update <- phaseHandle "raid_update"
  reset_success <- phaseHandle "reset_success"
  reset_failure <- phaseHandle "reset_failure"
  end <- phaseHandle "end"

  setPhase raid_update $ \(HAEvent eid (RaidUpdate{..}) _) -> do
    let
      (Node nid) = ruNode
      go [] = return ()
      go ((sdev, path, _sn):xs) = do
        fork CopyNewerBuffer $ do
          phaseLog "action" $ "Metadrive drive " ++ show path
                            ++ "failed on " ++ show nid ++ "."
          msgUuid <- liftIO $ nextRandom
          put Local $ Just (nid, msgUuid, sdev, ruRaidDevice, path)
          -- Tell SSPL to remove the drive from the array
          removed <- sendNodeCmd nid (Just msgUuid)
                      (NodeRaidCmd ruRaidDevice (RaidRemove path))
          -- Start the reset operation for this disk
          if removed
          then do
            promulgateRC $ ResetAttempt sdev
            switch [reset_success, reset_failure, timeout 120 end]
          else do
            phaseLog "error" $ "Failed to send ResetAttept command via SSPL."
            continue end
        go xs

    todo eid
    go ruFailedComponents
    done eid

  setPhaseIf reset_success
    -- TODO: relies on drive reset rule; TODO: nicer local state
    ( \(HAEvent eid (ResetSuccess x) _) _ l -> case l of
        Just (_,_,y,_,_) | x == y -> return $ Just eid
        _ -> return Nothing
    ) $ \eid -> do
      todo eid
      Just (nid, _, _, device, path) <- get Local
      -- Add drive back into array
      void $ sendNodeCmd nid Nothing (NodeRaidCmd device (RaidAdd path))
      done eid
      -- At this point we are done
      continue end

  setPhaseIf reset_failure
    ( \(HAEvent eid (ResetFailure x) _) _ l -> case l of
        Just (_,_,y,_,_) | x == y -> return $ Just eid
        _ -> return Nothing
    ) $ \eid -> do
      todo eid
      -- TODO: log an IEM (SEM?) here that things are wrong
      done eid
      continue end

  directly end stop

  startFork raid_update Nothing
