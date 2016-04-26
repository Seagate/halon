-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Module containing some reset bits that multiple rules may want access to
module HA.RecoveryCoordinator.Rules.Castor.Reset
  ( handleResetExternal
  , handleResetInternal
  , ResetAttempt(..)
  , resetAttemptThreshold
  , ruleResetAttempt
  ) where

import HA.EventQueue.Types
  ( HAEvent(..)
  , UUID
  )
import HA.RecoveryCoordinator.Actions.Core
  ( LoopState
  , getLocalGraph
  , messageProcessed
  , promulgateRC
  , syncGraph
  , unlessM
  , whenM
  )
import HA.RecoveryCoordinator.Actions.Hardware
import HA.RecoveryCoordinator.Actions.Mero.Conf
  ( lookupConfObjByFid
  , lookupStorageDevice
  , lookupStorageDeviceSDev
  )
import HA.RecoveryCoordinator.Rules.Mero.Conf (notifyDriveStateChange)
import HA.Resources (Node(..))
import HA.Resources.Castor
import HA.Resources.Mero.Note (ConfObjectState(..), getConfObjState)
import HA.Services.SSPL.CEP
  ( sendNodeCmd
  , updateDriveManagerWithFailure
  )
import HA.Services.SSPL.LL.Resources
  ( AckReply(..)
  , CommandAck(..)
  , NodeCmd(..)
  , commandAck
  )

import Mero.Notification (Set(..))
import Mero.Notification.HAState (Note(..))

import Control.Distributed.Process
  ( Process
  , say
  )
import Control.Monad
  ( forM_
  , when
  , unless
  )
import Control.Monad.IO.Class

import Data.Binary (Binary)
import Data.Foldable (for_)
import Data.Text (Text, pack)
import Data.Typeable (Typeable)
import Debug.Trace (traceEventIO)

import GHC.Generics (Generic)

import Network.CEP hiding (phaseLog)
import qualified Network.CEP as C

phaseLog :: String -> String -> PhaseM g l ()
phaseLog t m = liftProcess . say $ t ++ " => " ++ m

--------------------------------------------------------------------------------
-- Reset bit                                                                  --
--------------------------------------------------------------------------------

-- | When the number of reset attempts is greater than this threshold, a 'Disk'
--   should be in 'DiskFailure' status.
resetAttemptThreshold :: Int
resetAttemptThreshold = 10

-- | Time to allow for SSPL to reply on a reset request.
driveResetTimeout :: Int
driveResetTimeout = 5*60

-- | Time to allow for SSPL reply on a smart test request.
smartTestTimeout :: Int
smartTestTimeout = 15*60

-- | Event sent when to many failures has been sent for a 'Disk'.
data ResetAttempt = ResetAttempt StorageDevice
  deriving (Eq, Generic, Show, Typeable)

instance Binary ResetAttempt

-- | Event sent when a ResetAttempt were successful.
newtype ResetSuccess =
    ResetSuccess StorageDevice
    deriving (Eq, Show, Binary)

-- | Event sent when a ResetAttempt failed.
newtype ResetFailure =
    ResetFailure StorageDevice
    deriving (Eq, Show, Binary)

-- | Drive state change handler for 'reset' functionality.
--
--   Called whenever a drive changes state. This function is
--   responsible for potentially starting a reset attempt on
--   one or more drives.
handleResetExternal :: Set -> PhaseM LoopState l ()
handleResetExternal (Set ns) = do
  liftIO $ traceEventIO "START mero-halon:external-handler:reset"
  for_ ns $ \(Note mfid tpe) ->
    case tpe of
      _ | tpe == M0_NC_TRANSIENT || tpe == M0_NC_FAILED -> do
        sdevm <- lookupConfObjByFid mfid
        for_ sdevm $ \m0sdev -> do
          msdev <- lookupStorageDevice m0sdev
          case msdev of
            Just sdev -> do
              -- Drive reset rule may be triggered if drive is removed, we
              -- can't do anything sane here, so skipping this rule.
              mstatus <- driveStatus sdev
              phaseLog "info" $ "handleReset for " ++ show (sdev, mstatus)
              case (\(StorageDeviceStatus s _) -> s) <$> mstatus of
                Just "EMPTY" ->
                   phaseLog "info" "drive is physically removed, skipping reset"
                _ -> do
                  st <- getConfObjState m0sdev <$> getLocalGraph

                  unless (st == M0_NC_FAILED) $ do
                    ongoing <- hasOngoingReset sdev
                    if ongoing
                    then phaseLog "info" $ "Reset ongoing on a drive - ignoring message"
                    else do
                      ratt <- getDiskResetAttempts sdev
                      let status = if ratt <= resetAttemptThreshold
                                   then M0_NC_TRANSIENT
                                   else M0_NC_FAILED

                      -- We handle this status inside external rule, because we need to
                      -- update drive manager if and only if failure is set because of
                      -- mero notifications, not because drive removal or other event.
                      when (status == M0_NC_FAILED) $
                        updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "MERO-Timeout")

                      -- Notify rest of system if stat actually changed
                      when (st /= status) $
                        notifyDriveStateChange m0sdev status
 

                      syncGraph $ say "handleReset synchronized"
            _ -> do
              phaseLog "warning" $ "Cannot find all entities attached to M0"
                                ++ " storage device: "
                                ++ show m0sdev
                                ++ ": "
                                ++ show msdev
      _ -> return () -- Should we do anything here?
  liftIO $ traceEventIO "STOP mero-halon:external-handler:reset"

-- | Internal reset handler, if any drive changes state to a transient,
-- we need to run reset attempt.
handleResetInternal :: Set -> PhaseM LoopState l ()
handleResetInternal (Set ns) = do
  liftIO $ traceEventIO "START mero-halon:internal-handler:reset-attempt"
  for_ ns $ \(Note mfid tpe) ->
    case tpe of
      M0_NC_TRANSIENT -> do 
        sdevm <- lookupConfObjByFid mfid
        for_ sdevm $ \m0sdev ->  do
          msdev <- lookupStorageDevice m0sdev
          forM_ msdev $ \sdev ->  do
            phaseLog "info" $ "Starting reset attempt for " ++ show sdev
            promulgateRC $ ResetAttempt sdev
      _ -> return ()
  liftIO $ traceEventIO "STOP mero-halon:internal-handler:reset-attempt"

ruleResetAttempt :: Definitions LoopState ()
ruleResetAttempt = define "reset-attempt" $ do
      home          <- phaseHandle "home"
      reset         <- phaseHandle "reset"
      resetComplete <- phaseHandle "reset-complete"
      smart         <- phaseHandle "smart"
      smartSuccess  <- phaseHandle "smart-success"
      smartFailure  <- phaseHandle "smart-failure"
      failure       <- phaseHandle "failure"
      end           <- phaseHandle "end"

      setPhase home $ \(HAEvent uid (ResetAttempt sdev) _) -> fork NoBuffer $ do
        nodes <- getSDevNode sdev
        node <- case nodes of
          node:_ -> return node
          [] -> do
             -- XXX: send IEM message
             phaseLog "warning" $ "Can't perform query to SSPL as node can't be found"
             messageProcessed uid
             stop
        paths <- lookupStorageDeviceSerial sdev
        case paths of
          serial:_ -> do
            put Local (Just (sdev, pack serial, node, uid))
            unlessM (isStorageDevicePowered sdev) $ do
              phaseLog "info" $ "Device powered on: " ++ show sdev
              switch [resetComplete, timeout driveResetTimeout failure]
            whenM (isStorageDeviceRunningSmartTest sdev) $ do
              phaseLog "info" $ "Device running SMART test: " ++ show sdev
              switch [smartSuccess, smartFailure, timeout smartTestTimeout failure]
            markOnGoingReset sdev
            continue reset
          [] -> do
            -- XXX: send IEM message
            phaseLog "warning" $ "Cannot perform reset attempt for drive "
                              ++ show sdev
                              ++ " as it has no device paths associated."
            messageProcessed uid
            stop

      directly reset $ do
        Just (sdev, serial, Node nid, _) <- get Local
        i <- getDiskResetAttempts sdev
        if i <= resetAttemptThreshold
        then do
          incrDiskResetAttempts sdev
          sent <- sendNodeCmd nid Nothing (DriveReset serial)
          if sent
          then do markDiskPowerOff sdev
                  switch [resetComplete, timeout driveResetTimeout failure]
          else continue failure
        else continue failure

      setPhaseIf resetComplete (onCommandAck DriveReset) $ \(result, eid) -> do
        Just (sdev, _, _, _) <- get Local
        markResetComplete sdev
        if result
        then do markDiskPowerOn sdev
                messageProcessed eid
                continue smart
        else do messageProcessed eid
                continue failure

      directly smart $ do
        Just (sdev, serial, Node nid, _) <- get Local
        sent <- sendNodeCmd nid Nothing (SmartTest serial)
        if sent
        then do phaseLog "info" $ "Running SMART test on " ++ show sdev
                markSMARTTestIsRunning sdev
                switch [smartSuccess, smartFailure, timeout smartTestTimeout failure]
        else continue failure

      setPhaseIf smartSuccess onSmartSuccess $ \eid -> do
        Just (sdev, _, _, _) <- get Local
        phaseLog "info" $ "Successful SMART test on " ++ show sdev
        markSMARTTestComplete sdev
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev ->
          notifyDriveStateChange m0sdev M0_NC_ONLINE
        messageProcessed eid
        continue end

      setPhaseIf smartFailure onSmartFailure $ \eid -> do
        Just (sdev, _, _, _) <- get Local
        phaseLog "info" $ "SMART test failed on " ++ show sdev
        markSMARTTestComplete sdev
        messageProcessed eid
        continue failure

      directly failure $ do
        Just (sdev, _, _, _) <- get Local
        phaseLog "info" $ "Drive reset failure for " ++ show sdev
        sd <- lookupStorageDeviceSDev sdev
        forM_ sd $ \m0sdev -> do
          updateDriveManagerWithFailure sdev "HALON-FAILED" (Just "MERO-Timeout")
          -- Let note handler deal with repair logic
          notifyDriveStateChange m0sdev M0_NC_FAILED
        continue end

      directly end $ do
        Just (_, _, _, uid) <- get Local
        messageProcessed uid
        stop

      start home Nothing


--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

-- | States of the Timeout rule.OB
data TimeoutState = TimeoutNormal | ResetAttemptSent

onCommandAck :: (Text -> NodeCmd)
           -> HAEvent CommandAck
           -> g
           -> Maybe (StorageDevice, Text, Node, UUID)
           -> Process (Maybe (Bool, UUID))
onCommandAck _ _ _ Nothing = return Nothing
onCommandAck k (HAEvent eid cmd _) _ (Just (_, serial, _, _)) =
  case commandAckType cmd of
    Just x | (k serial) == x -> return $ Just
              (commandAck cmd == AckReplyPassed, eid)
           | otherwise       -> return Nothing
    _ -> return Nothing

onSmartSuccess :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, Text, Node, UUID)
               -> Process (Maybe UUID)
onSmartSuccess (HAEvent eid cmd _) _ (Just (_, serial, _, _)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | serial == x ->
          case commandAck cmd of
            AckReplyPassed -> return $ Just eid
            _              -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartSuccess _ _ _ = return Nothing

onSmartFailure :: HAEvent CommandAck
               -> g
               -> Maybe (StorageDevice, Text, Node, UUID)
               -> Process (Maybe UUID)
onSmartFailure (HAEvent eid cmd _) _ (Just (_, serial, _, _)) =
    case commandAckType cmd of
      Just (SmartTest x)
        | serial == x ->
          case commandAck cmd of
            AckReplyFailed  -> return $ Just eid
            AckReplyError _ -> return $ Just eid
            _               -> return Nothing
        | otherwise -> return Nothing
      _ -> return Nothing
onSmartFailure _ _ _ = return Nothing
